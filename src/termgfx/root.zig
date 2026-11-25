//! Terminal Graphics Protocol Encoders & Detection
//!
//! Pure, zero-SDL encoders and environment-based protocol detection for
//! rendering image previews directly in terminal emulators (Kitty Graphics
//! Protocol `t=t`, VT340 Sixel, iTerm2 Inline Images OSC 1337, and ANSI
//! truecolor Unicode half-blocks).

const detect = @import("detect.zig");
const geom = @import("geom");
const halfblocks = @import("halfblocks.zig");
const iterm2 = @import("iterm2.zig");
const kitty = @import("kitty.zig");
const sixel = @import("sixel.zig");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

pub const CellDims = detect.CellDims;
pub const CellPixelSize = detect.CellPixelSize;
pub const cellsToPixels = detect.cellsToPixels;
pub const default_cell_px = detect.default_cell_px;
pub const Protocol = detect.Protocol;
pub const ProtocolMode = detect.ProtocolMode;
pub const queryCellPixelSize = detect.queryCellPixelSize;
pub const ResolvedTarget = detect.ResolvedTarget;
pub const TransportMode = detect.TransportMode;
pub const protocol_modes_string = detect.protocol_modes_string;

/// Options controlling terminal graphics framing (`TransportMode` and
/// optional target cell grid / cell pixel size for Kitty `U=1` placeholders).
pub const PreviewOptions = struct {
    transport: TransportMode = .direct,
    cell_dims: ?CellDims = null,
    cell_px: ?CellPixelSize = null,
};

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

/// Payload for ANSI 24-bit truecolor Unicode half-blocks emission directly
/// from in-memory RGBA32 pixels.
pub const HalfblocksPixelsPayload = struct {
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
};

/// Protocol-tagged payload for terminal graphics preview emission.
pub const PreviewPayload = union(Protocol) {
    kitty: KittyFilePayload,
    sixel: SixelPixelsPayload,
    iterm2: Iterm2Payload,
    halfblocks: HalfblocksPixelsPayload,
};

/// Zero-allocation `std.Io.Writer` wrapper that escapes `\x1b` as `\x1b\x1b`
/// for `tmux` DCS passthrough (`\x1bPtmux;...\x1b\\`).
const TmuxPassthroughWriter = struct {
    inner: *std.Io.Writer,
    interface: std.Io.Writer,

    fn init(inner: *std.Io.Writer, buf: []u8) TmuxPassthroughWriter {
        return .{
            .inner = inner,
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buf,
            },
        };
    }

    fn writeEscaped(
        inner: *std.Io.Writer,
        bytes: []const u8,
    ) std.Io.Writer.Error!void {
        var rest = bytes;
        while (std.mem.findScalar(u8, rest, '\x1b')) |esc_idx| {
            if (esc_idx > 0) try inner.writeAll(rest[0..esc_idx]);
            try inner.writeAll("\x1b\x1b");
            rest = rest[esc_idx + 1 ..];
        }
        if (rest.len > 0) try inner.writeAll(rest);
    }

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *TmuxPassthroughWriter = @fieldParentPtr("interface", w);
        if (w.end > 0) {
            try writeEscaped(self.inner, w.buffer[0..w.end]);
            w.end = 0;
        }
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try writeEscaped(self.inner, slice);
            consumed += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try writeEscaped(self.inner, last);
            consumed += last.len;
        }
        return consumed;
    }
};

fn writePayloadRaw(
    writer: *std.Io.Writer,
    payload: PreviewPayload,
    cell_px: ?CellPixelSize,
) !void {
    return switch (payload) {
        .kitty => |k| kitty.writeKittyStandard(
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
        .halfblocks => |hb| halfblocks.writeHalfblocksPreview(
            writer,
            hb.rgba_pixels,
            hb.pitch,
            hb.dims,
            cell_px,
        ),
    };
}

fn validatePayload(payload: PreviewPayload) !void {
    switch (payload) {
        .kitty => |k| {
            if (std.base64.standard.Encoder.calcSize(k.temp_path.len) > 512) {
                return error.PathTooLong;
            }
        },
        .iterm2 => |it| {
            if (it.dims.w == 0 or it.dims.h == 0) {
                return error.InvalidDimensions;
            }
            if (it.image_bytes.len == 0) return error.EmptyPayload;
        },
        .sixel => |s| {
            if (s.dims.w == 0 or s.dims.h == 0) return error.InvalidDimensions;
            if (s.dims.w > 4096 or s.dims.h > 4096) {
                return error.DimensionsTooLarge;
            }
            const row_bytes = @as(u64, s.dims.w) * 4;
            if (s.pitch < row_bytes) return error.InvalidPitch;
            if (@as(u64, s.dims.h - 1) *| @as(u64, s.pitch) +| row_bytes >
                s.rgba_pixels.len)
            {
                return error.BufferTooSmall;
            }
        },
        .halfblocks => |hb| {
            if (hb.dims.w == 0 or hb.dims.h == 0) {
                return error.InvalidDimensions;
            }
            if (hb.dims.w > 4096 or hb.dims.h > 4096) {
                return error.DimensionsTooLarge;
            }
            const row_bytes = @as(u64, hb.dims.w) * 4;
            if (hb.pitch < row_bytes) return error.InvalidPitch;
            if (@as(u64, hb.dims.h - 1) *| @as(u64, hb.pitch) +| row_bytes >
                hb.rgba_pixels.len)
            {
                return error.BufferTooSmall;
            }
        },
    }
}

/// Encodes and writes `payload` to `writer` using its tagged terminal
/// graphics protocol, applying `opts` (Kitty `U=1` Unicode placeholders and
/// `tmux` DCS passthrough wrapping).
// TODO(termgfx): For `.iterm2` inside `tmux`, query cell pixel height via
// `TIOCGWINSZ` (`ws_ypixel / ws_row`) to advance `tmux`'s cursor by the
// exact image row height after passthrough without over-scrolling.
pub fn writePreview(
    writer: *std.Io.Writer,
    payload: PreviewPayload,
    opts: PreviewOptions,
) !void {
    switch (opts.transport) {
        .direct => return writePayloadRaw(writer, payload, opts.cell_px),
        .tmux_unicode_placeholders => switch (payload) {
            .kitty => |k| return kitty.writeKittyUnicodePlaceholder(
                writer,
                k.temp_path,
                k.dims,
                opts.cell_dims,
                opts.cell_px,
            ),
            .sixel, .iterm2 => return writeTmuxPassthrough(
                writer,
                payload,
                opts.cell_px,
            ),
            .halfblocks => return writePayloadRaw(
                writer,
                payload,
                opts.cell_px,
            ),
        },
        .tmux_passthrough => switch (payload) {
            .kitty, .sixel, .iterm2 => return writeTmuxPassthrough(
                writer,
                payload,
                opts.cell_px,
            ),
            .halfblocks => return writePayloadRaw(
                writer,
                payload,
                opts.cell_px,
            ),
        },
    }
}

fn writeTmuxPassthrough(
    writer: *std.Io.Writer,
    payload: PreviewPayload,
    cell_px: ?CellPixelSize,
) !void {
    try validatePayload(payload);
    try writer.writeAll("\x1bPtmux;");
    var tmux_buf: [4 * 1024]u8 = undefined;
    var tmux_w = TmuxPassthroughWriter.init(writer, &tmux_buf);
    try writePayloadRaw(&tmux_w.interface, payload, cell_px);
    try tmux_w.interface.flush();
    try writer.writeAll("\x1b\\");
}

test "writePreview formats Kitty t=t, Sixel, iTerm2, and tmux passthrough" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writePreview(&w, .{
        .kitty = .{
            .temp_path = "/dev/shm/a.rgba",
            .dims = .{ .w = 320, .h = 240 },
            .clear_first = false,
        },
    }, .{});
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
    }, .{});
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
        }, .{}),
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
    }, .{});
    try std.testing.expect(
        std.mem.startsWith(u8, aw.written(), "\x1bP0;1;0q\"1;1;1;1"),
    );

    var w4 = std.Io.Writer.fixed(&buf);
    try writePreview(&w4, .{
        .iterm2 = .{
            .image_bytes = "abc",
            .dims = .{ .w = 16, .h = 12 },
        },
    }, .{});
    try std.testing.expectEqualStrings(
        "\x1b]1337;File=inline=1;size=3;width=16px;height=12px;" ++
            "preserveAspectRatio=1:YWJj\x07",
        w4.buffered(),
    );

    // tmux DCS passthrough wraps payload and doubles every inner ESC byte.
    var w5 = std.Io.Writer.fixed(&buf);
    try writePreview(&w5, .{
        .iterm2 = .{
            .image_bytes = "abc",
            .dims = .{ .w = 16, .h = 12 },
        },
    }, .{ .transport = .tmux_passthrough });
    try std.testing.expectEqualStrings(
        "\x1bPtmux;\x1b\x1b]1337;File=inline=1;size=3;" ++
            "width=16px;height=12px;preserveAspectRatio=1:YWJj\x07\x1b\\",
        w5.buffered(),
    );

    // Halfblocks render natively without tmux DCS passthrough.
    var w6 = std.Io.Writer.fixed(&buf);
    try writePreview(&w6, .{
        .halfblocks = .{
            .rgba_pixels = &px,
            .pitch = 4,
            .dims = .{ .w = 1, .h = 1 },
        },
    }, .{ .transport = .tmux_passthrough });
    try std.testing.expectEqualStrings(
        "\x1b[38;2;255;0;0m\xe2\x96\x80\x1b[0m",
        w6.buffered(),
    );
}

test {
    _ = detect;
    _ = halfblocks;
    _ = iterm2;
    _ = kitty;
    _ = sixel;
}
