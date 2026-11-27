const base64 = @import("base64.zig");
const geom = @import("geom");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

/// Streaming chunk size in raw input bytes (exact multiple of 3 so only the
/// final chunk can emit base64 `=` padding).
const raw_chunk_bytes: usize = 3 * 1024;
const b64_chunk_bytes: usize = 4 * 1024;

/// Encodes `image_bytes` (PNG or JPEG) into an iTerm2 Inline Images Protocol
/// (OSC 1337) escape sequence streamed directly to `writer` using fixed stack
/// buffers (zero heap allocations).
pub fn writeIterm2Preview(
    writer: *std.Io.Writer,
    image_bytes: []const u8,
    dims: PositiveDimsU32,
) !void {
    if (dims.w == 0 or dims.h == 0) return error.InvalidDimensions;
    if (image_bytes.len == 0) return error.EmptyPayload;

    try writer.print(
        "\x1b]1337;File=inline=1;size={d};width={d}px;height={d}px;" ++
            "preserveAspectRatio=1:",
        .{ image_bytes.len, dims.w, dims.h },
    );

    var b64_buf: [b64_chunk_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < image_bytes.len) {
        const end = @min(offset +| raw_chunk_bytes, image_bytes.len);
        const encoded = base64.encode(&b64_buf, image_bytes[offset..end]);
        try writer.writeAll(encoded);
        offset = end;
    }

    try writer.writeByte('\x07');
}

test "writeIterm2Preview formats OSC 1337 sequence with exact base64" {
    const allocator = std.testing.allocator;
    const sample = "hello world";
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeIterm2Preview(&aw.writer, sample, .{ .w = 320, .h = 240 });
    try std.testing.expectEqualStrings(
        "\x1b]1337;File=inline=1;size=11;width=320px;height=240px;" ++
            "preserveAspectRatio=1:aGVsbG8gd29ybGQ=\x07",
        aw.written(),
    );
}

test "writeIterm2Preview streams multi-chunk payloads identically to one-shot" {
    const allocator = std.testing.allocator;
    var payload: [raw_chunk_bytes * 2 + 17]u8 = undefined;
    for (&payload, 0..) |*b, idx| {
        b.* = @truncate(idx *% 31 +% 7);
    }

    const expected_b64 = try allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(payload.len),
    );
    defer allocator.free(expected_b64);
    _ = std.base64.standard.Encoder.encode(expected_b64, &payload);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeIterm2Preview(&aw.writer, &payload, .{ .w = 800, .h = 600 });

    const out = aw.written();
    const prefix =
        "\x1b]1337;File=inline=1;size=6161;width=800px;height=600px;" ++
        "preserveAspectRatio=1:";
    try std.testing.expect(std.mem.startsWith(u8, out, prefix));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x07"));
    try std.testing.expectEqualStrings(
        expected_b64,
        out[prefix.len .. out.len - 1],
    );
}

test "writeIterm2Preview rejects empty payload and zero dimensions" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(
        error.EmptyPayload,
        writeIterm2Preview(&w, "", .{ .w = 10, .h = 10 }),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        writeIterm2Preview(&w, "x", .{ .w = 0, .h = 10 }),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        writeIterm2Preview(&w, "x", .{ .w = 10, .h = 0 }),
    );
}
