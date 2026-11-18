//! SDL3 Low-Level Platform Abstraction Module
//!
//! Idiomatic Zig wrappers around SDL3 C APIs for window management,
//! GPU command buffers, event polling, surfaces, and fonts.

const builtin = @import("builtin");
const std = @import("std");

pub const events = @import("events.zig");
pub const font = @import("font.zig");
pub const gpu = @import("gpu.zig");
pub const keys = @import("keys.zig");
pub const surface = @import("surface.zig");
pub const window = @import("window.zig");

const has_glibc_malloc_trim = builtin.link_libc and
    builtin.os.tag == .linux and
    builtin.abi.isGnu();

extern "c" fn malloc_trim(pad: usize) c_int;

/// Returns unused freed pages from C `malloc` arenas (including worker thread
/// arenas created by `SDL_image` / `SDL_Surface` decodes) to the OS kernel.
pub fn reclaimProcessHeap() void {
    if (comptime has_glibc_malloc_trim) {
        _ = malloc_trim(0);
    }
}

pub const Color = font.Color;
pub const disableScreenSaver = window.disableScreenSaver;
pub const enableScreenSaver = window.enableScreenSaver;
pub const Event = events.Event;
pub const event_type = events.event_type;
pub const Font = font.Font;
pub const getError = events.getError;
pub const hint = events.hint;
pub const init = events.init;
pub const init_flags = events.init_flags;
pub const initTtf = font.initTtf;
pub const mouse = events.mouse;
pub const PixelFormat = surface.PixelFormat;
pub const quit = events.quit;
pub const quitTtf = font.quitTtf;
pub const ScaleMode = surface.ScaleMode;
pub const Surface = surface.Surface;
pub const Window = window.Window;
pub const window_flags = window.window_flags;

test "sdl enum mapping and boundary sanity checks" {
    const c = @import("c.zig").c;

    // ScaleMode roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_NEAREST),
        @backingInt(ScaleMode.nearest),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_LINEAR),
        @backingInt(ScaleMode.linear),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_PIXELART),
        @backingInt(ScaleMode.pixel_art),
    );

    // GPU Filter roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_FILTER_NEAREST),
        @backingInt(gpu.Filter.nearest),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_FILTER_LINEAR),
        @backingInt(gpu.Filter.linear),
    );

    // GPU SamplerAddressMode roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE),
        @backingInt(gpu.SamplerAddressMode.clamp_to_edge),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT),
        @backingInt(gpu.SamplerAddressMode.repeat),
    );

    // GPU CompareOp roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_COMPAREOP_ALWAYS),
        @backingInt(gpu.CompareOp.always),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_COMPAREOP_NEVER),
        @backingInt(gpu.CompareOp.never),
    );

    // GPU BlendFactor roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_SRC_ALPHA),
        @backingInt(gpu.BlendFactor.src_alpha),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA),
        @backingInt(gpu.BlendFactor.one_minus_src_alpha),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ONE),
        @backingInt(gpu.BlendFactor.one),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ZERO),
        @backingInt(gpu.BlendFactor.zero),
    );

    // GPU Texture handle equality
    var dummy_val: usize = 42;
    var dummy_val2: usize = 43;
    const dummy_ptr: *c.SDL_GPUTexture = @ptrCast(&dummy_val);
    const dummy_ptr2: *c.SDL_GPUTexture = @ptrCast(&dummy_val2);
    const t1 = gpu.Texture{ .ptr = dummy_ptr };
    const t2 = gpu.Texture{ .ptr = dummy_ptr };
    const t3 = gpu.Texture{ .ptr = dummy_ptr2 };
    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(!t1.eql(t3));
}

test {
    _ = @import("surface.zig");
    _ = @import("events.zig");
    _ = @import("font.zig");
    _ = @import("gpu.zig");
    _ = @import("keys.zig");
    _ = @import("window.zig");
}
