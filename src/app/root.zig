//! Application Core Module
//!
//! Encapsulates domain sub-states, background event handling, file I/O,
//! IPC protocol handling, image decoding pipelines, and system update passes.

pub const state = @import("state.zig");
pub const palette = @import("palette.zig");
pub const fs = @import("fs.zig");
pub const image = @import("image.zig");
pub const view_transform = @import("view_transform.zig");
pub const exif = @import("exif.zig");
pub const actions = @import("actions.zig");
pub const systems = @import("systems/root.zig");
pub const workers = @import("workers/root.zig");

test {
    _ = state;
    _ = palette;
    _ = fs;
    _ = image;
    _ = view_transform;
    _ = exif;
    _ = actions;
    _ = systems;
    _ = workers;
}
