//! Portable SIMD Standard Base64 Encoder (RFC 4648)
//!
//! Encodes 12 raw input bytes into 16 standard base64 ASCII characters per
//! `@Vector(16, u8)` iteration using `@shuffle` and branchless range offsets,
//! delegating the trailing `< 12`-byte tail to `std.base64.standard.Encoder`.

const std = @import("std");

const Vec12 = @Vector(12, u8);
const Vec16 = @Vector(16, u8);
const ShiftVec16 = @Vector(16, u3);

const hi_shuffle: [16]i32 = .{
    0, 0, 1,  2,
    3, 3, 4,  5,
    6, 6, 7,  8,
    9, 9, 10, 11,
};

const lo_shuffle: [16]i32 = .{
    0, 1,  2,  2,
    3, 4,  5,  5,
    6, 7,  8,  8,
    9, 10, 11, 11,
};

const mask_hi: Vec16 = .{
    0x00, 0x03, 0x0F, 0x3F,
    0x00, 0x03, 0x0F, 0x3F,
    0x00, 0x03, 0x0F, 0x3F,
    0x00, 0x03, 0x0F, 0x3F,
};

const shl_hi: ShiftVec16 = .{
    0, 4, 2, 0,
    0, 4, 2, 0,
    0, 4, 2, 0,
    0, 4, 2, 0,
};

const shr_lo: ShiftVec16 = .{
    2, 4, 6, 0,
    2, 4, 6, 0,
    2, 4, 6, 0,
    2, 4, 6, 0,
};

const mask_lo: Vec16 = .{
    0x3F, 0x0F, 0x03, 0x00,
    0x3F, 0x0F, 0x03, 0x00,
    0x3F, 0x0F, 0x03, 0x00,
    0x3F, 0x0F, 0x03, 0x00,
};

/// Returns the exact base64-encoded byte length (including `=` padding) for an
/// input of `source_size` raw bytes.
pub fn calcSize(source_size: usize) usize {
    return std.base64.standard.Encoder.calcSize(source_size);
}

inline fn encodeBlock12(block: *const [12]u8) [16]u8 {
    const in: Vec12 = block.*;
    const hi_src: Vec16 = @shuffle(u8, in, undefined, hi_shuffle);
    const lo_src: Vec16 = @shuffle(u8, in, undefined, lo_shuffle);

    const idx: Vec16 =
        ((hi_src & mask_hi) << shl_hi) | ((lo_src >> shr_lo) & mask_lo);

    const zero: Vec16 = @splat(0);
    const base: Vec16 = @splat(65);
    const d_lower = @select(
        u8,
        idx >= @as(Vec16, @splat(26)),
        @as(Vec16, @splat(6)),
        zero,
    );
    const d_digit = @select(
        u8,
        idx >= @as(Vec16, @splat(52)),
        @as(Vec16, @splat(256 - 75)),
        zero,
    );
    const d_plus = @select(
        u8,
        idx == @as(Vec16, @splat(62)),
        @as(Vec16, @splat(256 - 15)),
        zero,
    );
    const d_slash = @select(
        u8,
        idx == @as(Vec16, @splat(63)),
        @as(Vec16, @splat(256 - 12)),
        zero,
    );

    return idx +% base +% d_lower +% d_digit +% d_plus +% d_slash;
}

/// Encodes `source` into non-overlapping `dest` using RFC 4648 standard base64
/// with `=` padding, returning the written slice
/// `dest[0..calcSize(source.len)]`. Asserts `dest.len >= calcSize(source.len)`.
pub fn encode(noalias dest: []u8, noalias source: []const u8) []const u8 {
    const out_len = calcSize(source.len);
    std.debug.assert(dest.len >= out_len);

    var in_pos: usize = 0;
    var out_pos: usize = 0;
    while (source.len - in_pos >= 12) : ({
        in_pos += 12;
        out_pos += 16;
    }) {
        dest[out_pos..][0..16].* = encodeBlock12(source[in_pos..][0..12]);
    }

    if (in_pos < source.len) {
        _ = std.base64.standard.Encoder.encode(
            dest[out_pos..],
            source[in_pos..],
        );
    }

    return dest[0..out_len];
}

test "encode matches std.base64.standard across lengths 0..128" {
    var src_buf: [128]u8 = undefined;
    for (&src_buf, 0..) |*b, i| {
        b.* = @truncate(i *% 37 +% 13);
    }
    var got_buf: [calcSize(128)]u8 = undefined;
    var exp_buf: [calcSize(128)]u8 = undefined;

    for (0..src_buf.len + 1) |len| {
        const src = src_buf[0..len];
        const got = encode(&got_buf, src);
        const exp = std.base64.standard.Encoder.encode(&exp_buf, src);
        try std.testing.expectEqualStrings(exp, got);
    }
}

test "encode covers all 64 alphabet symbols in every 6-bit lane" {
    // Construct 64 * 3 = 192 raw bytes where every 6-bit value 0..63 appears
    // in all four output lanes of a 3-byte group.
    var src: [64 * 3]u8 = undefined;
    for (0..64) |v| {
        const s: u8 = @intCast(v);
        src[v * 3 + 0] = (s << 2) | (s >> 4);
        src[v * 3 + 1] = (s << 4) | (s >> 2);
        src[v * 3 + 2] = (s << 6) | s;
    }

    var got_buf: [calcSize(src.len)]u8 = undefined;
    var exp_buf: [calcSize(src.len)]u8 = undefined;
    const got = encode(&got_buf, &src);
    const exp = std.base64.standard.Encoder.encode(&exp_buf, &src);
    try std.testing.expectEqualStrings(exp, got);
}

test "encode matches std.base64.standard on 3072-byte Kitty chunk" {
    var src: [3072]u8 = undefined;
    for (&src, 0..) |*b, i| {
        b.* = @truncate((i *% 251) ^ (i >> 3));
    }
    var got_buf: [4096]u8 = undefined;
    var exp_buf: [4096]u8 = undefined;
    const got = encode(&got_buf, &src);
    const exp = std.base64.standard.Encoder.encode(&exp_buf, &src);
    try std.testing.expectEqualStrings(exp, got);
}
