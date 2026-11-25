//! Pure-Zig Terminal UI Subsystem (`peng-tui`)
//!
//! Provides `libvaxis`-backed input translation, infobar/overlay layout, and
//! terminal presentation helpers without depending on SDL or `app`.

pub const canvas = @import("canvas.zig");
pub const input = @import("input.zig");

test {
    _ = canvas;
    _ = input;
}
