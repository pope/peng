const detect = @import("detect.zig");
const geom = @import("geom");
const std = @import("std");

const CellPixelSize = detect.CellPixelSize;
const PositiveDimsU32 = geom.PositiveDimsU32;

const upper_half_block = "\xe2\x96\x80"; // U+2580 '▀'
const lower_half_block = "\xe2\x96\x84"; // U+2584 '▄'

/// 24-bit sRGB color triplet sampled from an RGBA32 image buffer.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Returns `true` when both RGB triplets have identical channels.
    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// Sampled terminal cell color: either `.default` (transparent) or 24-bit RGB.
pub const ColorState = union(enum) {
    default,
    rgb: Rgb,

    /// Returns `true` when both color states match.
    pub fn eql(a: ColorState, b: ColorState) bool {
        return switch (a) {
            .default => switch (b) {
                .default => true,
                .rgb => false,
            },
            .rgb => |ar| switch (b) {
                .default => false,
                .rgb => |br| ar.eql(br),
            },
        };
    }
};

fn readPixel(
    rgba_pixels: []const u8,
    pitch: usize,
    x: u32,
    y: u32,
) ColorState {
    const off = @as(usize, y) * pitch + @as(usize, x) * 4;
    const a = rgba_pixels[off + 3];
    if (a < 128) return .default;
    return .{
        .rgb = .{
            .r = rgba_pixels[off],
            .g = rgba_pixels[off + 1],
            .b = rgba_pixels[off + 2],
        },
    };
}

const U8Decimal = struct {
    bytes: [3]u8,
    len: u8,
};

const u8_decimal_lut: [256]U8Decimal = blk: {
    var table: [256]U8Decimal = undefined;
    for (0..256) |v| {
        if (v >= 100) {
            table[v] = .{
                .bytes = .{
                    @intCast('0' + (v / 100)),
                    @intCast('0' + (v / 10) % 10),
                    @intCast('0' + (v % 10)),
                },
                .len = 3,
            };
        } else if (v >= 10) {
            table[v] = .{
                .bytes = .{
                    @intCast('0' + (v / 10)),
                    @intCast('0' + (v % 10)),
                    0,
                },
                .len = 2,
            };
        } else {
            table[v] = .{
                .bytes = .{ @intCast('0' + v), 0, 0 },
                .len = 1,
            };
        }
    }
    break :blk table;
};

fn writeSgrRgb(
    writer: *std.Io.Writer,
    prefix: *const [7]u8,
    c: Rgb,
) !void {
    // Max length: "\x1b[38;2;255;255;255m" = 19 bytes; 24 bytes guarantees
    // every fixed 3-byte LUT store (`buf[pos..][0..3]`) stays in bounds.
    var buf: [24]u8 = undefined;
    buf[0..7].* = prefix.*;
    var pos: usize = 7;

    const r = u8_decimal_lut[c.r];
    buf[pos..][0..3].* = r.bytes;
    pos += r.len;
    buf[pos] = ';';
    pos += 1;

    const g = u8_decimal_lut[c.g];
    buf[pos..][0..3].* = g.bytes;
    pos += g.len;
    buf[pos] = ';';
    pos += 1;

    const b = u8_decimal_lut[c.b];
    buf[pos..][0..3].* = b.bytes;
    pos += b.len;
    buf[pos] = 'm';
    pos += 1;

    try writer.writeAll(buf[0..pos]);
}

fn setFg(
    writer: *std.Io.Writer,
    cur_fg: *ColorState,
    desired: ColorState,
) !void {
    if (cur_fg.eql(desired)) return;
    switch (desired) {
        .default => try writer.writeAll("\x1b[39m"),
        .rgb => |c| try writeSgrRgb(writer, "\x1b[38;2;", c),
    }
    cur_fg.* = desired;
}

fn setBg(
    writer: *std.Io.Writer,
    cur_bg: *ColorState,
    desired: ColorState,
) !void {
    if (cur_bg.eql(desired)) return;
    switch (desired) {
        .default => try writer.writeAll("\x1b[49m"),
        .rgb => |c| try writeSgrRgb(writer, "\x1b[48;2;", c),
    }
    cur_bg.* = desired;
}

/// SIMD-accelerated alpha-weighted box sampler mapping half-block cell
/// `(cx, hy)` in a `(cols x half_rows)` grid onto RGBA32 source `rgba_pixels`
/// (`dims`, row stride `pitch`). Caller must validate `dims`, `pitch`, and
/// `rgba_pixels.len` before calling.
pub fn sampleBox(
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
    cx: u32,
    cols: u32,
    hy: u32,
    half_rows: u32,
) ColorState {
    if (dims.w == 0 or dims.h == 0 or cols == 0 or half_rows == 0 or
        cx >= cols or hy >= half_rows)
    {
        return .default;
    }
    const Vec8u16 = @Vector(8, u16);
    const Vec8u32 = @Vector(8, u32);

    const x0: u32 = @intCast((@as(u64, cx) * dims.w) / cols);
    const x1_raw: u32 = @intCast(((@as(u64, cx) + 1) * dims.w) / cols);
    const x1: u32 = @max(x0 + 1, @min(x1_raw, dims.w));
    const y0: u32 = @intCast((@as(u64, hy) * dims.h) / half_rows);
    const y1_raw: u32 = @intCast(((@as(u64, hy) + 1) * dims.h) / half_rows);
    const y1: u32 = @max(y0 + 1, @min(y1_raw, dims.h));

    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var sum_a: u64 = 0;
    const count: u64 = @as(u64, x1 - x0) * @as(u64, y1 - y0);

    // Per-row 32-bit SIMD accumulators cannot overflow:
    // max row width (4096) * 255 * 255 = 266,342,400 < maxInt(u32).
    var y = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(usize, y) * pitch;
        var row_r: Vec8u32 = @splat(0);
        var row_g: Vec8u32 = @splat(0);
        var row_b: Vec8u32 = @splat(0);
        var row_a: Vec8u32 = @splat(0);

        var x = x0;
        while (x + 8 <= x1) : (x += 8) {
            const base = row_off + @as(usize, x) * 4;
            var rv: [8]u16 = undefined;
            var gv: [8]u16 = undefined;
            var bv: [8]u16 = undefined;
            var av: [8]u16 = undefined;
            inline for (0..8) |i| {
                rv[i] = rgba_pixels[base + i * 4 + 0];
                gv[i] = rgba_pixels[base + i * 4 + 1];
                bv[i] = rgba_pixels[base + i * 4 + 2];
                av[i] = rgba_pixels[base + i * 4 + 3];
            }
            const r16: Vec8u16 = rv;
            const g16: Vec8u16 = gv;
            const b16: Vec8u16 = bv;
            const a16: Vec8u16 = av;

            row_r += @as(Vec8u32, r16 * a16);
            row_g += @as(Vec8u32, g16 * a16);
            row_b += @as(Vec8u32, b16 * a16);
            row_a += @as(Vec8u32, a16);
        }

        sum_r += @reduce(.Add, row_r);
        sum_g += @reduce(.Add, row_g);
        sum_b += @reduce(.Add, row_b);
        sum_a += @reduce(.Add, row_a);

        while (x < x1) : (x += 1) {
            const off = row_off + @as(usize, x) * 4;
            const a: u64 = rgba_pixels[off + 3];
            sum_r += @as(u64, rgba_pixels[off]) * a;
            sum_g += @as(u64, rgba_pixels[off + 1]) * a;
            sum_b += @as(u64, rgba_pixels[off + 2]) * a;
            sum_a += a;
        }
    }

    if ((sum_a + count / 2) / count < 128) return .default;
    return .{
        .rgb = .{
            .r = @intCast((sum_r + sum_a / 2) / sum_a),
            .g = @intCast((sum_g + sum_a / 2) / sum_a),
            .b = @intCast((sum_b + sum_a / 2) / sum_a),
        },
    };
}

/// Encodes an RGBA32 pixel buffer (`dims.w` x `dims.h`, row stride `pitch`)
/// into ANSI 24-bit truecolor Unicode half-block rows (`▀`/`▄`/space).
/// When `cell_px` is provided, box-filters the source image into terminal
/// cells preserving true physical aspect ratio (`cell_w` x `cell_h / 2` per
/// half-block). When `cell_px` is `null`, maps 1:1 (1 col x 2 vertical pixels).
pub fn writeHalfblocksPreview(
    writer: *std.Io.Writer,
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
    cell_px: ?CellPixelSize,
) !void {
    if (dims.w == 0 or dims.h == 0) return error.InvalidDimensions;
    if (dims.w > 4096 or dims.h > 4096) return error.DimensionsTooLarge;
    const row_bytes = @as(u64, dims.w) * 4;
    if (pitch < row_bytes) return error.InvalidPitch;
    const required = @as(u64, dims.h - 1) *| @as(u64, pitch) +| row_bytes;
    if (required > rgba_pixels.len) return error.BufferTooSmall;

    const Grid = struct { w: u32, h: u32, direct: bool };
    const grid: Grid = if (cell_px) |cp| blk: {
        const cw: u64 = @max(1, cp.w);
        const ch: u64 = @max(1, cp.h);
        const cols: u32 = @intCast(@max(1, (@as(u64, dims.w) + cw / 2) / cw));
        const hrows: u32 = @intCast(
            @max(1, (@as(u64, dims.h) * 2 + ch / 2) / ch),
        );
        break :blk .{ .w = cols, .h = hrows, .direct = false };
    } else .{ .w = dims.w, .h = dims.h, .direct = true };

    var y: u32 = 0;
    while (y < grid.h) : (y += 2) {
        var cur_fg: ColorState = .default;
        var cur_bg: ColorState = .default;
        const has_bot = (y + 1 < grid.h);

        var x: u32 = 0;
        while (x < grid.w) : (x += 1) {
            const top = if (grid.direct)
                readPixel(rgba_pixels, pitch, x, y)
            else
                sampleBox(rgba_pixels, pitch, dims, x, grid.w, y, grid.h);
            const bot: ColorState = if (has_bot)
                if (grid.direct)
                    readPixel(rgba_pixels, pitch, x, y + 1)
                else
                    sampleBox(
                        rgba_pixels,
                        pitch,
                        dims,
                        x,
                        grid.w,
                        y + 1,
                        grid.h,
                    )
            else
                .default;

            if (top.eql(bot)) {
                try setBg(writer, &cur_bg, top);
                try writer.writeByte(' ');
            } else if (top == .default) {
                try setFg(writer, &cur_fg, bot);
                try setBg(writer, &cur_bg, .default);
                try writer.writeAll(lower_half_block);
            } else {
                try setFg(writer, &cur_fg, top);
                try setBg(writer, &cur_bg, bot);
                try writer.writeAll(upper_half_block);
            }
        }

        try writer.writeAll("\x1b[0m");
        if (y + 2 < grid.h) {
            try writer.writeByte('\n');
        }
    }
}

test "writeHalfblocksPreview encodes top/bottom pairs and RLE solid runs" {
    const allocator = std.testing.allocator;
    // 2x2: top row red/red, bottom row blue/blue
    const px = [_]u8{
        255, 0, 0,   255, 255, 0, 0,   255,
        0,   0, 255, 255, 0,   0, 255, 255,
    };
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeHalfblocksPreview(&aw.writer, &px, 8, .{ .w = 2, .h = 2 }, null);
    try std.testing.expectEqualStrings(
        "\x1b[38;2;255;0;0m\x1b[48;2;0;0;255m" ++
            upper_half_block ++ upper_half_block ++ "\x1b[0m",
        aw.written(),
    );

    // 2x2 uniform green uses space + single bg SGR
    const solid = [_]u8{
        0, 200, 0, 255, 0, 200, 0, 255,
        0, 200, 0, 255, 0, 200, 0, 255,
    };
    var aw2 = std.Io.Writer.Allocating.init(allocator);
    defer aw2.deinit();
    try writeHalfblocksPreview(
        &aw2.writer,
        &solid,
        8,
        .{ .w = 2, .h = 2 },
        null,
    );
    try std.testing.expectEqualStrings(
        "\x1b[48;2;0;200;0m  \x1b[0m",
        aw2.written(),
    );
}

test "writeHalfblocksPreview handles odd height and transparency" {
    const allocator = std.testing.allocator;
    // 1x3: transparent, green, red
    const px = [_]u8{
        0,   0,   0, 0,
        0,   255, 0, 255,
        255, 0,   0, 255,
    };
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeHalfblocksPreview(&aw.writer, &px, 4, .{ .w = 1, .h = 3 }, null);
    try std.testing.expectEqualStrings(
        "\x1b[38;2;0;255;0m" ++ lower_half_block ++ "\x1b[0m\n" ++
            "\x1b[38;2;255;0;0m" ++ upper_half_block ++ "\x1b[0m",
        aw.written(),
    );
}

test "writeHalfblocksPreview box-filters non-1:2 cell_px aspect ratio" {
    const allocator = std.testing.allocator;
    // 4x6 image with cell_px = 2x6 (aspect 3.0):
    // cols = round(4/2) = 2, half_rows = round(12/6) = 2 (1 terminal row).
    // Top 3 rows red, bottom 3 rows blue -> 2 red/blue half-block columns.
    var px: [4 * 6 * 4]u8 = undefined;
    for (0..6) |row| {
        const is_top = row < 3;
        for (0..4) |col| {
            const off = (row * 4 + col) * 4;
            px[off] = if (is_top) 200 else 0;
            px[off + 1] = 0;
            px[off + 2] = if (is_top) 0 else 100;
            px[off + 3] = 255;
        }
    }
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeHalfblocksPreview(
        &aw.writer,
        &px,
        16,
        .{ .w = 4, .h = 6 },
        .{ .w = 2, .h = 6 },
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;2;200;0;0m\x1b[48;2;0;0;100m" ++
            upper_half_block ++ upper_half_block ++ "\x1b[0m",
        aw.written(),
    );

    // 19x4 image with cell_px = 19x4 exercises 2x8-pixel SIMD batches + 3-px
    // scalar tail per row with non-uniform RGB and varying alpha:
    // Top 2 rows: cols 0..16 = (200, 40, 20, a=200), cols 16..19 = (0, 200,
    // 220, a=100). Per row: sum_a = 16*200 + 3*100 = 3500,
    // r = round(16*200*200 / 3500) = 183, g = round((16*40*200 + 3*200*100) /
    // 3500) = 54, b = round((16*20*200 + 3*220*100) / 3500) = 37.
    // Bottom 2 rows: solid (30, 180, 90, 255).
    var wide: [19 * 4 * 4]u8 = undefined;
    for (0..4) |row| {
        const is_top = row < 2;
        for (0..19) |col| {
            const off = (row * 19 + col) * 4;
            if (is_top) {
                const is_tail = col >= 16;
                wide[off] = if (is_tail) 0 else 200;
                wide[off + 1] = if (is_tail) 200 else 40;
                wide[off + 2] = if (is_tail) 220 else 20;
                wide[off + 3] = if (is_tail) 100 else 200;
            } else {
                wide[off] = 30;
                wide[off + 1] = 180;
                wide[off + 2] = 90;
                wide[off + 3] = 255;
            }
        }
    }
    var aw2 = std.Io.Writer.Allocating.init(allocator);
    defer aw2.deinit();
    try writeHalfblocksPreview(
        &aw2.writer,
        &wide,
        19 * 4,
        .{ .w = 19, .h = 4 },
        .{ .w = 19, .h = 4 },
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;2;183;54;37m\x1b[48;2;30;180;90m" ++
            upper_half_block ++ "\x1b[0m",
        aw2.written(),
    );
}

test "writeHalfblocksPreview validates dimensions, pitch, and buffer size" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const px = [_]u8{ 1, 2, 3, 255 };
    try std.testing.expectError(
        error.InvalidDimensions,
        writeHalfblocksPreview(&w, &px, 4, .{ .w = 0, .h = 1 }, null),
    );
    try std.testing.expectError(
        error.InvalidPitch,
        writeHalfblocksPreview(&w, &px, 2, .{ .w = 1, .h = 1 }, null),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        writeHalfblocksPreview(&w, &px, 4, .{ .w = 1, .h = 2 }, null),
    );
    try std.testing.expectError(
        error.DimensionsTooLarge,
        writeHalfblocksPreview(&w, &px, 4, .{ .w = 4097, .h = 1 }, null),
    );

    // Padded row stride (pitch > w * 4) skips trailing padding bytes.
    const padded = [_]u8{
        10, 20, 30, 255, 99, 99, 99, 99,
        40, 50, 60, 255, 88, 88, 88, 88,
    };
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeHalfblocksPreview(
        &aw.writer,
        &padded,
        8,
        .{ .w = 1, .h = 2 },
        null,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;2;10;20;30m\x1b[48;2;40;50;60m" ++
            upper_half_block ++ "\x1b[0m",
        aw.written(),
    );
}
