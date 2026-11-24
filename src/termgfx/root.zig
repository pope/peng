//! Terminal Graphics Protocol Encoders & Detection
//!
//! Pure, zero-SDL encoders and environment-based protocol detection for
//! rendering image previews directly in terminal emulators (Kitty Graphics
//! Protocol `t=t`, VT340 Sixel, and iTerm2 Inline Images OSC 1337).

const detect = @import("detect.zig");
const geom = @import("geom");
const iterm2 = @import("iterm2.zig");
const sixel = @import("sixel.zig");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

pub const Protocol = detect.Protocol;
pub const ProtocolMode = detect.ProtocolMode;
pub const protocol_modes_string = detect.protocol_modes_string;

/// Payload for Kitty Graphics Protocol `t=t` emission from an RGBA32 temp
/// file.
pub const KittyFilePayload = struct {
    temp_path: []const u8,
    dims: PositiveDimsU32,
    clear_first: bool = false,
};

/// Payload for VT340 Sixel emission directly from in-memory RGBA32 pixels.
pub const SixelPixelsPayload = struct {
    allocator: std.mem.Allocator,
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
};

/// Payload for iTerm2 Inline Images (OSC 1337) emission from encoded PNG or
/// JPEG bytes.
pub const Iterm2Payload = struct {
    image_bytes: []const u8,
    dims: PositiveDimsU32,
};

/// Protocol-tagged payload for terminal graphics preview emission.
pub const PreviewPayload = union(Protocol) {
    kitty: KittyFilePayload,
    sixel: SixelPixelsPayload,
    iterm2: Iterm2Payload,
};

fn writeKittyPreview(
    writer: *std.Io.Writer,
    temp_path: []const u8,
    dims: PositiveDimsU32,
    clear_first: bool,
) !void {
    var b64_buf: [512]u8 = undefined;
    if (std.base64.standard.Encoder.calcSize(temp_path.len) > b64_buf.len) {
        return error.PathTooLong;
    }
    const encoded = std.base64.standard.Encoder.encode(&b64_buf, temp_path);
    const clear_seq = if (clear_first) "\x1b_Ga=d,d=A,q=2\x1b\\" else "";
    try writer.print(
        "{s}\x1b_Ga=T,f=32,s={d},v={d},t=t,q=2;{s}\x1b\\",
        .{ clear_seq, dims.w, dims.h, encoded },
    );
}

/// Encodes and writes `payload` to `writer` using its tagged terminal
/// graphics protocol.
pub fn writePreview(
    writer: *std.Io.Writer,
    payload: PreviewPayload,
) !void {
    return switch (payload) {
        .kitty => |k| writeKittyPreview(
            writer,
            k.temp_path,
            k.dims,
            k.clear_first,
        ),
        .sixel => |s| sixel.writeSixelPreview(
            s.allocator,
            writer,
            s.rgba_pixels,
            s.pitch,
            s.dims,
        ),
        .iterm2 => |it| iterm2.writeIterm2Preview(
            writer,
            it.image_bytes,
            it.dims,
        ),
    };
}

test "writePreview formats Kitty t=t and Sixel escape sequences" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writePreview(&w, .{
        .kitty = .{
            .temp_path = "/dev/shm/a.rgba",
            .dims = .{ .w = 320, .h = 240 },
            .clear_first = false,
        },
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,f=32,s=320,v=240,t=t,q=2;L2Rldi9zaG0vYS5yZ2Jh\x1b\\",
        w.buffered(),
    );

    var w2 = std.Io.Writer.fixed(&buf);
    try writePreview(&w2, .{
        .kitty = .{
            .temp_path = "/dev/shm/a.rgba",
            .dims = .{ .w = 320, .h = 240 },
            .clear_first = true,
        },
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=A,q=2\x1b\\" ++
            "\x1b_Ga=T,f=32,s=320,v=240,t=t,q=2;L2Rldi9zaG0vYS5yZ2Jh\x1b\\",
        w2.buffered(),
    );

    const long_path: [400]u8 = @splat('a');
    var w3 = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        error.PathTooLong,
        writePreview(&w3, .{
            .kitty = .{
                .temp_path = &long_path,
                .dims = .{ .w = 10, .h = 10 },
                .clear_first = false,
            },
        }),
    );

    var px: [4]u8 = .{ 255, 0, 0, 255 };
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writePreview(&aw.writer, .{
        .sixel = .{
            .allocator = std.testing.allocator,
            .rgba_pixels = &px,
            .pitch = 4,
            .dims = .{ .w = 1, .h = 1 },
        },
    });
    try std.testing.expect(
        std.mem.startsWith(u8, aw.written(), "\x1bP0;1;0q\"1;1;1;1"),
    );

    var w4 = std.Io.Writer.fixed(&buf);
    try writePreview(&w4, .{
        .iterm2 = .{
            .image_bytes = "abc",
            .dims = .{ .w = 16, .h = 12 },
        },
    });
    try std.testing.expectEqualStrings(
        "\x1b]1337;File=inline=1;size=3;width=16px;height=12px;" ++
            "preserveAspectRatio=1:YWJj\x07",
        w4.buffered(),
    );
}

test {
    _ = detect;
    _ = iterm2;
    _ = sixel;
}
