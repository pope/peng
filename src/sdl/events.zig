const builtin = @import("builtin");
const c_pkg = @import("c.zig");
const std = @import("std");

const c = c_pkg.c;

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

    /// Queries the current mouse position in window coordinates and returns
    /// the pressed button bitmask.
    pub fn getState(x: *f32, y: *f32) u32 {
        return c.SDL_GetMouseState(x, y);
    }
};

/// Event type constants corresponding to SDL3 window, keyboard, touch, and input events.
pub const event_type = struct {
    pub const quit = c.SDL_EVENT_QUIT;
    pub const window_shown = c.SDL_EVENT_WINDOW_SHOWN;
    pub const window_exposed = c.SDL_EVENT_WINDOW_EXPOSED;
    pub const window_minimized = c.SDL_EVENT_WINDOW_MINIMIZED;
    pub const window_maximized = c.SDL_EVENT_WINDOW_MAXIMIZED;
    pub const window_restored = c.SDL_EVENT_WINDOW_RESTORED;
    pub const mouse_enter = c.SDL_EVENT_WINDOW_MOUSE_ENTER;
    pub const mouse_leave = c.SDL_EVENT_WINDOW_MOUSE_LEAVE;
    pub const window_close_requested = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    pub const window_occluded = c.SDL_EVENT_WINDOW_OCCLUDED;
    pub const window_enter_fullscreen = c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN;
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
};

/// SDL configuration hints interface.
pub const hint = struct {
    /// Sets an SDL hint key-value pair, returning `true` on success.
    pub fn set(name: [:0]const u8, value: [:0]const u8) bool {
        return c.SDL_SetHint(name.ptr, value.ptr);
    }
};

const has_posix_signals = std.posix.Sigaction != void;

var terminate_signal_received: std.atomic.Value(bool) = .init(false);

const posix_sig = if (has_posix_signals) struct {
    var signal_forwarded_to_main: std.atomic.Value(bool) = .init(false);
    var handlers_installed: bool = false;
    var orig_sig_int: std.posix.Sigaction = undefined;
    var orig_sig_term: std.posix.Sigaction = undefined;
    var sdl_sig_int: std.posix.Sigaction = undefined;
    var sdl_sig_term: std.posix.Sigaction = undefined;
    var main_pthread: if (std.Thread.use_pthreads)
        std.c.pthread_t
    else
        void = undefined;

    fn callSavedHandler(
        saved: *const std.posix.Sigaction,
        sig: std.posix.SIG,
    ) void {
        if ((saved.flags & std.posix.SA.SIGINFO) != 0) return;
        if (saved.handler.handler) |h| {
            if (h != std.posix.SIG.DFL and
                h != std.posix.SIG.IGN and
                h != handleTerminateSignal)
            {
                h(sig);
            }
        }
    }

    fn handleTerminateSignal(sig: std.posix.SIG) callconv(.c) void {
        const saved_errno = if (comptime builtin.link_libc)
            std.c._errno().*
        else {};
        defer if (comptime builtin.link_libc) {
            std.c._errno().* = saved_errno;
        };

        const was_forwarded = signal_forwarded_to_main.swap(false, .acq_rel);
        const already_pending = terminate_signal_received.swap(true, .acq_rel);
        if (already_pending and !was_forwarded) {
            const dfl_act: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(sig, &dfl_act, null);
            _ = std.c.raise(sig);
            return;
        }

        switch (sig) {
            .INT => callSavedHandler(&sdl_sig_int, sig),
            .TERM => callSavedHandler(&sdl_sig_term, sig),
            else => {},
        }
        if (comptime std.Thread.use_pthreads) {
            const self_thread = std.c.pthread_self();
            if (self_thread != main_pthread) {
                signal_forwarded_to_main.store(true, .release);
                _ = std.c.pthread_kill(main_pthread, sig);
            }
        }
    }

    fn preInit() void {
        signal_forwarded_to_main.store(false, .release);
        if (comptime std.Thread.use_pthreads) {
            main_pthread = std.c.pthread_self();
        }
        if (!handlers_installed) {
            // Save original dispositions and reset SIGINT/SIGTERM to SIG_DFL
            // before SDL_Init so SDL always installs its internal handler.
            const dfl_act: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &dfl_act, &orig_sig_int);
            std.posix.sigaction(.TERM, &dfl_act, &orig_sig_term);
        }
    }

    fn postInit() void {
        if (!handlers_installed) {
            // Capture SDL's installed handlers into sdl_sig_* before
            // registering handleTerminateSignal so they are initialized prior
            // to any asynchronous signal invocation.
            std.posix.sigaction(.INT, null, &sdl_sig_int);
            std.posix.sigaction(.TERM, null, &sdl_sig_term);

            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = handleTerminateSignal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &act, null);
            std.posix.sigaction(.TERM, &act, null);
            handlers_installed = true;
        }
    }

    fn restoreBeforeQuit() void {
        if (handlers_installed) {
            std.posix.sigaction(.INT, &sdl_sig_int, null);
            std.posix.sigaction(.TERM, &sdl_sig_term, null);
        }
    }

    fn restoreAfterQuit() void {
        if (handlers_installed) {
            std.posix.sigaction(.INT, &orig_sig_int, null);
            std.posix.sigaction(.TERM, &orig_sig_term, null);
            handlers_installed = false;
        }
        signal_forwarded_to_main.store(false, .release);
    }
} else struct {};

/// Atomically consumes and clears any pending `SIGINT` or `SIGTERM` process
/// termination signal flag.
pub fn consumeTerminateSignal() bool {
    return terminate_signal_received.swap(false, .acq_rel);
}

/// Initializes specified SDL subsystems.
pub fn init(flags: u32) bool {
    terminate_signal_received.store(false, .release);
    if (comptime has_posix_signals) {
        posix_sig.preInit();
    }
    if (!c.SDL_Init(flags)) {
        if (comptime has_posix_signals) {
            if (!posix_sig.handlers_installed) {
                std.posix.sigaction(.INT, &posix_sig.orig_sig_int, null);
                std.posix.sigaction(.TERM, &posix_sig.orig_sig_term, null);
            }
        }
        return false;
    }
    if (comptime has_posix_signals) {
        posix_sig.postInit();
    }
    return true;
}

/// Returns a bitmask of the specified SDL subsystems that are initialized.
pub fn wasInit(flags: u32) u32 {
    return c.SDL_WasInit(flags);
}

/// Cleans up and terminates all initialized SDL subsystems.
pub fn quit() void {
    if (comptime has_posix_signals) {
        posix_sig.restoreBeforeQuit();
    }
    c.SDL_Quit();
    if (comptime has_posix_signals) {
        posix_sig.restoreAfterQuit();
    }
    terminate_signal_received.store(false, .release);
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

test "POSIX signal handler captures SIGINT and restores disposition on quit" {
    if (comptime !has_posix_signals) return error.SkipZigTest;

    var prev_int: std.posix.Sigaction = undefined;
    const ign_act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &ign_act, &prev_int);
    defer std.posix.sigaction(.INT, &prev_int, null);

    try std.testing.expect(init(init_flags.events));
    errdefer quit();

    if (comptime builtin.link_libc) {
        std.c._errno().* = 42;
    }
    _ = std.c.raise(.INT);
    if (comptime builtin.link_libc) {
        try std.testing.expectEqual(@as(c_int, 42), std.c._errno().*);
    }

    try std.testing.expect(consumeTerminateSignal());
    try std.testing.expect(!consumeTerminateSignal());

    quit();

    var restored_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &restored_int);
    try std.testing.expectEqual(
        std.posix.SIG.IGN,
        restored_int.handler.handler,
    );
}
