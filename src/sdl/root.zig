//! SDL3 Low-Level Platform Abstraction Module
//!
//! Idiomatic Zig wrappers around SDL3 C APIs for window management,
//! GPU command buffers, event polling, surfaces, fonts, and timers.

const c_pkg = @import("c.zig");
pub const events = @import("events.zig");
pub const font = @import("font.zig");
pub const gpu = @import("gpu.zig");
pub const keys = @import("keys.zig");
const std = @import("std");
pub const surface = @import("surface.zig");
pub const timer = @import("timer.zig");
pub const window = @import("window.zig");

const c = c_pkg.c;

pub const Color = font.Color;
pub const Event = events.Event;
pub const event_type = events.event_type;
pub const FColor = c.SDL_FColor;
pub const Font = font.Font;
pub const FPoint = c.SDL_FPoint;
pub const FRect = c.SDL_FRect;
pub const getError = events.getError;
pub const hint = events.hint;
pub const init = events.init;
pub const init_flags = events.init_flags;
pub const initTtf = font.initTtf;
pub const mouse = events.mouse;
pub const PixelFormat = surface.PixelFormat;
pub const quit = events.quit;
pub const quitTtf = font.quitTtf;
pub const Rect = c.SDL_Rect;
pub const ScaleMode = surface.ScaleMode;
pub const Surface = surface.Surface;
pub const Vertex = c.SDL_Vertex;
pub const Window = window.Window;
pub const window_flags = window.window_flags;

test "sdl enum mapping and boundary sanity checks" {

    // ScaleMode roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_NEAREST),
        @intFromEnum(ScaleMode.nearest),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_LINEAR),
        @intFromEnum(ScaleMode.linear),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_SCALEMODE_PIXELART),
        @intFromEnum(ScaleMode.pixel_art),
    );

    // GPU Filter roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_FILTER_NEAREST),
        @intFromEnum(gpu.Filter.nearest),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_FILTER_LINEAR),
        @intFromEnum(gpu.Filter.linear),
    );

    // GPU SamplerAddressMode roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE),
        @intFromEnum(gpu.SamplerAddressMode.clamp_to_edge),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT),
        @intFromEnum(gpu.SamplerAddressMode.repeat),
    );

    // GPU CompareOp roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_COMPAREOP_ALWAYS),
        @intFromEnum(gpu.CompareOp.always),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_COMPAREOP_NEVER),
        @intFromEnum(gpu.CompareOp.never),
    );

    // GPU BlendFactor roundtrip
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_SRC_ALPHA),
        @intFromEnum(gpu.BlendFactor.src_alpha),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA),
        @intFromEnum(gpu.BlendFactor.one_minus_src_alpha),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ONE),
        @intFromEnum(gpu.BlendFactor.one),
    );
    try std.testing.expectEqual(
        @as(c_int, c.SDL_GPU_BLENDFACTOR_ZERO),
        @intFromEnum(gpu.BlendFactor.zero),
    );

    // GPU Texture handle equality & opaque conversion
    var dummy_val: usize = 42;
    const dummy_ptr: *c.SDL_GPUTexture = @ptrCast(&dummy_val);
    const t1 = gpu.Texture{ .ptr = dummy_ptr };
    const t2 = gpu.Texture{ .ptr = dummy_ptr };
    try std.testing.expect(t1.eql(t2));
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(dummy_ptr)), t1.asOpaque());
}

test {
    _ = @import("surface.zig");
    _ = @import("events.zig");
    _ = @import("font.zig");
    _ = @import("gpu.zig");
    _ = @import("keys.zig");
    _ = @import("timer.zig");
    _ = @import("window.zig");
}
