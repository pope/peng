const detect = @import("detect.zig");
const geom = @import("geom");
const std = @import("std");

const CellDims = detect.CellDims;
const CellPixelSize = detect.CellPixelSize;
const PositiveDimsU32 = geom.PositiveDimsU32;

/// UTF-8 encoding of Kitty's Unicode placeholder codepoint `U+10EEEE`.
const placeholder_utf8 = "\xF4\x8E\xBB\xAE";

/// First 100 official Kitty row/column combining diacritics from
/// `kitty/gen/rowcolumn-diacritics.txt`.
const row_diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
    0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
    0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
    0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
    0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
    0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
    0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
    0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074A,
};

/// Fits pixel dimensions `img_dims` inside `max_cells` using `cell_px`
/// (or a standard ~1:2 terminal cell aspect ratio when `cell_px` is `null`).
fn fitCells(
    img_dims: PositiveDimsU32,
    max_cells: CellDims,
    cell_px: ?CellPixelSize,
) CellDims {
    if (img_dims.w == 0 or img_dims.h == 0 or
        max_cells.cols == 0 or max_cells.rows == 0)
    {
        return .{ .cols = 1, .rows = 1 };
    }
    const aspect: f64 = if (cell_px) |px|
        if (px.w > 0 and px.h > 0)
            @as(f64, @floatFromInt(px.h)) / @as(f64, @floatFromInt(px.w))
        else
            2.0
    else
        2.0;
    const w_f: f64 = @floatFromInt(img_dims.w);
    const h_f: f64 = @floatFromInt(img_dims.h);
    const max_c: f64 = @floatFromInt(max_cells.cols);
    const max_r: f64 = @floatFromInt(max_cells.rows);
    const scale = @min(max_c / w_f, (max_r * aspect) / h_f);
    const cols_f = @max(1.0, @min(max_c, @round(w_f * scale)));
    const rows_f = @max(1.0, @min(max_r, @round((h_f * scale) / aspect)));
    return .{
        .cols = @intFromFloat(cols_f),
        .rows = @intFromFloat(rows_f),
    };
}

fn writeUtf8Codepoint(writer: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try writer.writeAll(buf[0..len]);
}

/// Kitty Graphics Protocol pixel data transport medium:
/// - `.temp_file`: local temporary RGBA32 file (`t=t`, unlinked by terminal).
/// - `.direct_rgba`: inline 4096-byte base64 chunks (`t=d`, SSH-compatible).
pub const KittyMedium = union(enum) {
    temp_file: []const u8,
    direct_rgba: struct {
        rgba_pixels: []const u8,
        pitch: usize,
    },
};

/// Validates `medium` and `dims` before emitting any Kitty escape sequence.
pub fn validateMedium(medium: KittyMedium, dims: PositiveDimsU32) !void {
    if (dims.w == 0 or dims.h == 0) return error.InvalidDimensions;
    switch (medium) {
        .temp_file => |path| {
            if (std.base64.standard.Encoder.calcSize(path.len) > 512) {
                return error.PathTooLong;
            }
        },
        .direct_rgba => |d| {
            if (dims.w > 4096 or dims.h > 4096) return error.DimensionsTooLarge;
            const row_bytes = @as(u64, dims.w) * 4;
            if (d.pitch < row_bytes) return error.InvalidPitch;
            if (@as(u64, dims.h - 1) *| @as(u64, d.pitch) +| row_bytes >
                d.rgba_pixels.len)
            {
                return error.BufferTooSmall;
            }
        },
    }
}

/// Derives a deterministic non-zero 24-bit Kitty image ID from `medium` and
/// `dims` so the ID fits directly in an RGB foreground color
/// `\x1b[38;2;r;g;bm`.
fn imageIdFromMedium(medium: KittyMedium, dims: PositiveDimsU32) u24 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&dims.w));
    hasher.update(std.mem.asBytes(&dims.h));
    switch (medium) {
        .temp_file => |path| hasher.update(path),
        .direct_rgba => |d| {
            const row_bytes: usize = @as(usize, dims.w) * 4;
            const sample_len = @min(row_bytes, 256);
            const h_usize: usize = @intCast(dims.h);
            const sample_rows = [_]usize{ 0, h_usize / 2, h_usize - 1 };
            for (sample_rows) |row| {
                const start = row * d.pitch;
                hasher.update(d.rgba_pixels[start .. start + sample_len]);
            }
        },
    }
    const id: u24 = @truncate(hasher.final());
    return if (id == 0) 1 else id;
}

fn writeDirectRgbaChunks(
    writer: *std.Io.Writer,
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
    first_header: []const u8,
    tmux_wrap: bool,
) !void {
    const row_bytes: usize = @as(usize, dims.w) * 4;
    const total_bytes: usize = row_bytes * @as(usize, dims.h);
    // 3072 raw bytes encode to exactly 4096 base64 characters (Kitty chunk
    // limit).
    var raw_buf: [3072]u8 = undefined;
    var b64_buf: [4096]u8 = undefined;
    var raw_len: usize = 0;
    var emitted_bytes: usize = 0;
    var is_first = true;

    for (0..@as(usize, dims.h)) |row| {
        const row_start = row * pitch;
        var slice = rgba_pixels[row_start .. row_start + row_bytes];
        while (slice.len > 0) {
            const take = @min(slice.len, raw_buf.len - raw_len);
            @memcpy(raw_buf[raw_len .. raw_len + take], slice[0..take]);
            raw_len += take;
            slice = slice[take..];

            if (raw_len == raw_buf.len or
                emitted_bytes + raw_len == total_bytes)
            {
                emitted_bytes += raw_len;
                const more: u8 = if (emitted_bytes < total_bytes) 1 else 0;
                const encoded = std.base64.standard.Encoder.encode(
                    &b64_buf,
                    raw_buf[0..raw_len],
                );
                if (tmux_wrap) {
                    if (is_first) {
                        try writer.print(
                            "\x1bPtmux;\x1b\x1b_G{s},t=d,m={d};{s}\x1b\x1b\\" ++
                                "\x1b\\",
                            .{ first_header, more, encoded },
                        );
                    } else {
                        try writer.print(
                            "\x1bPtmux;\x1b\x1b_Gm={d};{s}\x1b\x1b\\\x1b\\",
                            .{ more, encoded },
                        );
                    }
                } else {
                    if (is_first) {
                        try writer.print(
                            "\x1b_G{s},t=d,m={d};{s}\x1b\\",
                            .{ first_header, more, encoded },
                        );
                    } else {
                        try writer.print(
                            "\x1b_Gm={d};{s}\x1b\\",
                            .{ more, encoded },
                        );
                    }
                }
                is_first = false;
                raw_len = 0;
            }
        }
    }
}

/// Writes a standard Kitty Graphics Protocol escape sequence (`t=t` or
/// chunked `t=d`) to `writer` using native pixel dimensions.
pub fn writeKittyStandard(
    writer: *std.Io.Writer,
    medium: KittyMedium,
    dims: PositiveDimsU32,
    clear_first: bool,
) !void {
    try validateMedium(medium, dims);
    if (clear_first) {
        try writer.writeAll("\x1b_Ga=d,d=A,q=2\x1b\\");
    }
    switch (medium) {
        .temp_file => |temp_path| {
            var b64_buf: [512]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(
                &b64_buf,
                temp_path,
            );
            try writer.print(
                "\x1b_Ga=T,f=32,s={d},v={d},t=t,q=2;{s}\x1b\\",
                .{ dims.w, dims.h, encoded },
            );
        },
        .direct_rgba => |d| {
            var hdr_buf: [96]u8 = undefined;
            const header = std.mem.print(
                &hdr_buf,
                "a=T,f=32,s={d},v={d},q=2",
                .{ dims.w, dims.h },
            ) catch unreachable;
            try writeDirectRgbaChunks(
                writer,
                d.rgba_pixels,
                d.pitch,
                dims,
                header,
                false,
            );
        },
    }
}

/// Writes a Kitty Graphics Protocol Unicode Placeholder (`U=1`) sequence for
/// `tmux`: uploads the virtual placement (`a=T,U=1,i=<id>,c=<cols>,r=<rows>`)
/// wrapped in `tmux` DCS passthrough (per-chunk for `t=d`), then emits plain
/// `U+10EEEE` placeholder text cells so `tmux` tracks placement cleanly.
pub fn writeKittyUnicodePlaceholder(
    writer: *std.Io.Writer,
    medium: KittyMedium,
    dims: PositiveDimsU32,
    cell_dims: ?CellDims,
    cell_px: ?CellPixelSize,
) !void {
    try validateMedium(medium, dims);

    const raw_cells = cell_dims orelse CellDims{ .cols = 80, .rows = 24 };
    const max_cells: CellDims = .{
        .cols = raw_cells.cols,
        .rows = @min(raw_cells.rows, @as(u32, row_diacritics.len)),
    };
    const fit = fitCells(dims, max_cells, cell_px);

    const id = imageIdFromMedium(medium, dims);
    switch (medium) {
        .temp_file => |temp_path| {
            var b64_buf: [512]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(
                &b64_buf,
                temp_path,
            );
            try writer.print(
                "\x1bPtmux;\x1b\x1b_Ga=T,U=1,f=32,s={d},v={d}," ++
                    "i={d},c={d},r={d},t=t,q=2;{s}\x1b\x1b\\\x1b\\",
                .{ dims.w, dims.h, id, fit.cols, fit.rows, encoded },
            );
        },
        .direct_rgba => |d| {
            var hdr_buf: [128]u8 = undefined;
            const header = std.mem.print(
                &hdr_buf,
                "a=T,U=1,f=32,s={d},v={d},i={d},c={d},r={d},q=2",
                .{ dims.w, dims.h, id, fit.cols, fit.rows },
            ) catch unreachable;
            try writeDirectRgbaChunks(
                writer,
                d.rgba_pixels,
                d.pitch,
                dims,
                header,
                true,
            );
        },
    }

    const r: u8 = @intCast((id >> 16) & 0xFF);
    const g: u8 = @intCast((id >> 8) & 0xFF);
    const b: u8 = @intCast(id & 0xFF);
    try writer.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });

    for (0..fit.rows) |row| {
        try writer.writeAll(placeholder_utf8);
        try writeUtf8Codepoint(writer, row_diacritics[row]);
        try writeUtf8Codepoint(writer, row_diacritics[0]);
        for (1..fit.cols) |_| {
            try writer.writeAll(placeholder_utf8);
        }
        if (row + 1 < fit.rows) {
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("\x1b[39m");
}

test "fitCells preserves aspect ratio for landscape and portrait images" {
    const land = fitCells(
        .{ .w = 400, .h = 266 },
        .{ .cols = 60, .rows = 30 },
        null,
    );
    try std.testing.expectEqual(@as(u32, 60), land.cols);
    try std.testing.expectEqual(@as(u32, 20), land.rows);

    const port = fitCells(
        .{ .w = 266, .h = 400 },
        .{ .cols = 60, .rows = 30 },
        null,
    );
    try std.testing.expectEqual(@as(u32, 40), port.cols);
    try std.testing.expectEqual(@as(u32, 30), port.rows);

    // Square 10x10 cells yield 1:1 cell aspect ratio.
    const sq = fitCells(
        .{ .w = 400, .h = 200 },
        .{ .cols = 40, .rows = 40 },
        .{ .w = 10, .h = 10 },
    );
    try std.testing.expectEqual(@as(u32, 40), sq.cols);
    try std.testing.expectEqual(@as(u32, 20), sq.rows);
}

test "writeKittyUnicodePlaceholder emits U=1 upload and U+10EEEE grid" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeKittyUnicodePlaceholder(
        &aw.writer,
        .{ .temp_file = "/dev/shm/a.rgba" },
        .{ .w = 400, .h = 200 },
        .{ .cols = 8, .rows = 4 },
        null,
    );
    const out = aw.written();
    try std.testing.expect(
        std.mem.startsWith(u8, out, "\x1bPtmux;\x1b\x1b_Ga=T,U=1,f=32,s=400,"),
    );
    try std.testing.expect(std.mem.find(u8, out, "c=8,r=2,t=t,q=2;") != null);
    try std.testing.expect(std.mem.find(u8, out, placeholder_utf8) != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[39m"));

    // 1-col / >100-row clamping preserves aspect ratio.
    var aw2 = std.Io.Writer.Allocating.init(allocator);
    defer aw2.deinit();
    try writeKittyUnicodePlaceholder(
        &aw2.writer,
        .{ .temp_file = "/dev/shm/b.rgba" },
        .{ .w = 200, .h = 400 },
        .{ .cols = 1, .rows = 150 },
        null,
    );
    const out2 = aw2.written();
    try std.testing.expect(
        std.mem.startsWith(u8, out2, "\x1bPtmux;\x1b\x1b_Ga=T,U=1,"),
    );
    try std.testing.expect(std.mem.find(u8, out2, "c=1,r=1,t=t,q=2;") != null);
}

test "writeKittyStandard and U=1 support direct_rgba chunking and pitch" {
    const allocator = std.testing.allocator;

    // 1x2 padded pitch (8 bytes per row, 4 bytes active): strips padding.
    const padded = [_]u8{
        1, 2, 3, 255, 99, 99, 99, 99,
        4, 5, 6, 255, 88, 88, 88, 88,
    };
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeKittyStandard(
        &aw.writer,
        .{ .direct_rgba = .{ .rgba_pixels = &padded, .pitch = 8 } },
        .{ .w = 1, .h = 2 },
        false,
    );
    // base64({1,2,3,255,4,5,6,255}) = "AQID/wQFBv8="
    try std.testing.expectEqualStrings(
        "\x1b_Ga=T,f=32,s=1,v=2,q=2,t=d,m=0;AQID/wQFBv8=\x1b\\",
        aw.written(),
    );

    // 32x32 RGBA = 4096 bytes -> 2 chunks (3072 bytes m=1, 1024 bytes m=0).
    const big: [32 * 32 * 4]u8 = @splat(0xAA);
    var aw2 = std.Io.Writer.Allocating.init(allocator);
    defer aw2.deinit();
    try writeKittyStandard(
        &aw2.writer,
        .{ .direct_rgba = .{ .rgba_pixels = &big, .pitch = 32 * 4 } },
        .{ .w = 32, .h = 32 },
        false,
    );
    const out2 = aw2.written();
    try std.testing.expect(
        std.mem.startsWith(u8, out2, "\x1b_Ga=T,f=32,s=32,v=32,q=2,t=d,m=1;"),
    );
    try std.testing.expect(std.mem.find(u8, out2, "\x1b\\\x1b_Gm=0;") != null);

    // U=1 tmux placeholder wraps each direct_rgba chunk in DCS passthrough.
    var aw3 = std.Io.Writer.Allocating.init(allocator);
    defer aw3.deinit();
    try writeKittyUnicodePlaceholder(
        &aw3.writer,
        .{ .direct_rgba = .{ .rgba_pixels = &big, .pitch = 32 * 4 } },
        .{ .w = 32, .h = 32 },
        .{ .cols = 4, .rows = 2 },
        null,
    );
    const out3 = aw3.written();
    try std.testing.expect(
        std.mem.startsWith(u8, out3, "\x1bPtmux;\x1b\x1b_Ga=T,U=1,f=32,s=32,"),
    );
    try std.testing.expect(
        std.mem.find(u8, out3, "\x1bPtmux;\x1b\x1b_Gm=0;") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, out3, "\x1b[39m"));

    // Exact 3072-byte chunk boundary (24x32 RGBA = 3072 bytes) emits a single
    // m=0 chunk with no empty trailing chunk.
    const exact: [24 * 32 * 4]u8 = @splat(0x55);
    var aw4 = std.Io.Writer.Allocating.init(allocator);
    defer aw4.deinit();
    try writeKittyStandard(
        &aw4.writer,
        .{ .direct_rgba = .{ .rgba_pixels = &exact, .pitch = 24 * 4 } },
        .{ .w = 24, .h = 32 },
        false,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        aw4.written(),
        "\x1b_Ga=T,f=32,s=24,v=32,q=2,t=d,m=0;",
    ));
    try std.testing.expect(std.mem.find(u8, aw4.written(), "m=1") == null);
}
