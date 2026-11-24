//! Terminal Graphics Protocol Encoders
//!
//! Pure, zero-SDL encoders for rendering image previews directly in terminal
//! emulators (currently Kitty Graphics Protocol `t=t`, extensible to Sixel,
//! iTerm2 inline images, etc.).

const geom = @import("geom");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

/// Writes a Kitty Graphics Protocol `t=t` escape sequence for raw RGBA32
/// temp file `temp_path` with dimensions `dims` to `writer`, optionally
/// clearing prior terminal graphics when `clear_first` is true.
pub fn writeKittyPreview(
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

test "writeKittyPreview formats t=t escape sequences with and without clear" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeKittyPreview(
        &w,
        "/dev/shm/a.rgba",
        .{ .w = 320, .h = 240 },
        false,
    );
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,f=32,s=320,v=240,t=t,q=2;L2Rldi9zaG0vYS5yZ2Jh\x1b\\",
        w.buffered(),
    );

    var w2 = std.Io.Writer.fixed(&buf);
    try writeKittyPreview(
        &w2,
        "/dev/shm/a.rgba",
        .{ .w = 320, .h = 240 },
        true,
    );
    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=A,q=2\x1b\\" ++
            "\x1b_Ga=T,f=32,s=320,v=240,t=t,q=2;L2Rldi9zaG0vYS5yZ2Jh\x1b\\",
        w2.buffered(),
    );

    const long_path: [400]u8 = @splat('a');
    var w3 = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        error.PathTooLong,
        writeKittyPreview(&w3, &long_path, .{ .w = 10, .h = 10 }, false),
    );
}
