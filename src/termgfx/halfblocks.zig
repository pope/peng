const detect = @import("detect.zig");
const geom = @import("geom");
const std = @import("std");

const CellPixelSize = detect.CellPixelSize;
const PositiveDimsU32 = geom.PositiveDimsU32;

const upper_half_block = "\xe2\x96\x80"; // U+2580 '▀'
const lower_half_block = "\xe2\x96\x84"; // U+2584 '▄'

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

const ColorState = union(enum) {
    default,
    rgb: Rgb,

    fn eql(a: ColorState, b: ColorState) bool {
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

fn setFg(
    writer: *std.Io.Writer,
    cur_fg: *ColorState,
    desired: ColorState,
) !void {
    if (cur_fg.eql(desired)) return;
    switch (desired) {
        .default => try writer.writeAll("\x1b[39m"),
        .rgb => |c| try writer.print(
            "\x1b[38;2;{d};{d};{d}m",
            .{ c.r, c.g, c.b },
        ),
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
        .rgb => |c| try writer.print(
            "\x1b[48;2;{d};{d};{d}m",
            .{ c.r, c.g, c.b },
        ),
    }
    cur_bg.* = desired;
}

fn sampleBox(
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
    cx: u32,
    cols: u32,
    hy: u32,
    half_rows: u32,
) ColorState {
    const x0: u32 = @intCast((@as(u64, cx) * dims.w) / cols);
    const x1_raw: u32 = @intCast((@as(u64, cx + 1) * dims.w) / cols);
    const x1: u32 = @max(x0 + 1, @min(x1_raw, dims.w));
    const y0: u32 = @intCast((@as(u64, hy) * dims.h) / half_rows);
    const y1_raw: u32 = @intCast((@as(u64, hy + 1) * dims.h) / half_rows);
    const y1: u32 = @max(y0 + 1, @min(y1_raw, dims.h));

    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var sum_a: u64 = 0;
    const count: u64 = @as(u64, x1 - x0) * @as(u64, y1 - y0);

    var y = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(usize, y) * pitch;
        var x = x0;
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
