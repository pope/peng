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

/// Derives a deterministic non-zero 24-bit Kitty image ID from `temp_path`
/// so the ID fits directly in an RGB foreground color `\x1b[38;2;r;g;bm`.
fn imageIdFromPath(temp_path: []const u8) u24 {
    const h = std.hash.Wyhash.hash(0, temp_path);
    const id: u24 = @truncate(h);
    return if (id == 0) 1 else id;
}

/// Writes a standard Kitty Graphics Protocol `t=t` escape sequence to
/// `writer` using native pixel dimensions (avoiding cell-aspect stretching).
pub fn writeKittyStandard(
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

/// Writes a Kitty Graphics Protocol Unicode Placeholder (`U=1`) sequence for
/// `tmux`: uploads the virtual placement (`a=T,U=1,i=<id>,c=<cols>,r=<rows>`)
/// wrapped in `tmux` DCS passthrough, then emits plain `U+10EEEE` placeholder
/// text cells so `tmux` tracks placement and clears the image cleanly on exit.
pub fn writeKittyUnicodePlaceholder(
    writer: *std.Io.Writer,
    temp_path: []const u8,
    dims: PositiveDimsU32,
    cell_dims: ?CellDims,
    cell_px: ?CellPixelSize,
) !void {
    var b64_buf: [512]u8 = undefined;
    if (std.base64.standard.Encoder.calcSize(temp_path.len) > b64_buf.len) {
        return error.PathTooLong;
    }
    const encoded = std.base64.standard.Encoder.encode(&b64_buf, temp_path);

    const raw_cells = cell_dims orelse CellDims{ .cols = 80, .rows = 24 };
    const max_cells: CellDims = .{
        .cols = raw_cells.cols,
        .rows = @min(raw_cells.rows, @as(u32, row_diacritics.len)),
    };
    const fit = fitCells(dims, max_cells, cell_px);

    const id = imageIdFromPath(temp_path);
    try writer.print(
        "\x1bPtmux;\x1b\x1b_Ga=T,U=1,f=32,s={d},v={d}," ++
            "i={d},c={d},r={d},t=t,q=2;{s}\x1b\x1b\\\x1b\\",
        .{ dims.w, dims.h, id, fit.cols, fit.rows, encoded },
    );

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
        "/dev/shm/a.rgba",
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
        "/dev/shm/b.rgba",
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
