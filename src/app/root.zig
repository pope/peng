//! Application Core Module
//!
//! Encapsulates domain sub-states, background event handling, file I/O,
//! IPC protocol handling, image decoding pipelines, and system update passes.

pub const state = @import("state.zig");
pub const input = @import("input");
pub const palette = @import("palette.zig");
pub const events = @import("events.zig");
pub const pipeline = @import("pipeline.zig");
pub const fs = @import("fs.zig");
pub const ipc = @import("ipc.zig");
pub const image = @import("image.zig");
pub const view_transform = @import("view_transform.zig");
pub const exif = @import("exif.zig");
pub const actions = @import("actions.zig");
pub const systems = @import("systems/root.zig");
pub const workers = @import("workers/root.zig");

test {
    _ = state;
    _ = input;
    _ = palette;
    _ = events;
    _ = pipeline;
    _ = fs;
    _ = ipc;
    _ = image;
    _ = view_transform;
    _ = exif;
    _ = actions;
    _ = systems;
    _ = workers;
}
