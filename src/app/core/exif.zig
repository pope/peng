const state_pkg = @import("state");
const std = @import("std");

const Orientation = state_pkg.Orientation;

/// Floating-point dimensions (width and height) of a JPEG image in pixels.
pub const JpegDimensions = struct { w: f32, h: f32 };

/// Parsed TIFF payload header located within an APP1 EXIF segment.
pub const TiffHeader = struct {
    tiff: []const u8,
    is_le: bool,
    ifd0_off: u32,
};

pub fn findTiffPayload(data: []const u8) ?TiffHeader {
    if (data.len < 14) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        const payload = data[idx + 2 .. idx + seg_len];
        idx += seg_len;

        if (marker == 0xE1) {
            if (payload.len < 14) continue;
            if (!std.mem.startsWith(u8, payload, "Exif\x00\x00")) continue;

            const tiff = payload[6..];
            if (tiff.len < 8) continue;

            const is_le = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else continue;

            const sig = if (is_le) std.mem.readInt(u16, tiff[2..4][0..2], .little) else std.mem.readInt(u16, tiff[2..4][0..2], .big);
            if (sig != 0x002A) continue;

            const ifd0_off = if (is_le) std.mem.readInt(u32, tiff[4..8][0..4], .little) else std.mem.readInt(u32, tiff[4..8][0..4], .big);
            if (ifd0_off >= tiff.len or ifd0_off + 2 > tiff.len) continue;

            return .{
                .tiff = tiff,
                .is_le = is_le,
                .ifd0_off = ifd0_off,
            };
        }
    }
    return null;
}

pub fn parseExifDimensions(data: []const u8) ?JpegDimensions {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    var width: ?u32 = null;
    var height: ?u32 = null;
    var exif_sub_ifd_off: ?u32 = null;

    const parseIfd = struct {
        fn run(t: []const u8, off: usize, le: bool, w_out: *?u32, h_out: *?u32, sub_out: ?*?u32) void {
            if (off >= t.len or off + 2 > t.len) return;
            const num = if (le) std.mem.readInt(u16, t[off..][0..2], .little) else std.mem.readInt(u16, t[off..][0..2], .big);
            var entry_off = off + 2;
            var i: usize = 0;
            while (i < num) : (i += 1) {
                if (entry_off + 12 > t.len) break;
                const entry = t[entry_off .. entry_off + 12];
                entry_off += 12;

                const tag = if (le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                const type_id = if (le) std.mem.readInt(u16, entry[2..4][0..2], .little) else std.mem.readInt(u16, entry[2..4][0..2], .big);

                var val: u32 = 0;
                if (type_id == 3) {
                    val = if (le) std.mem.readInt(u16, entry[8..10][0..2], .little) else std.mem.readInt(u16, entry[8..10][0..2], .big);
                } else if (type_id == 4) {
                    val = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                }

                if (tag == 0x0100 or tag == 0xA002) {
                    if (val > 0) w_out.* = val;
                } else if (tag == 0x0101 or tag == 0xA003) {
                    if (val > 0) h_out.* = val;
                } else if (tag == 0x8769 and sub_out != null) {
                    if (val > 0) sub_out.?.* = val;
                }
            }
        }
    }.run;

    parseIfd(tiff, ifd0_off, is_le, &width, &height, &exif_sub_ifd_off);

    if (exif_sub_ifd_off) |sub_off| {
        parseIfd(tiff, sub_off, is_le, &width, &height, null);
    }

    if (width != null and height != null) {
        return JpegDimensions{ .w = @floatFromInt(width.?), .h = @floatFromInt(height.?) };
    }
    return null;
}

pub fn readJpegDimensions(data: []const u8) ?JpegDimensions {
    if (parseExifDimensions(data)) |dims| return dims;
    if (data.len < 4) return null;
    if (data[0] != 0xFF or data[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or idx + seg_len > data.len) break;

        // Skip APP1 (0xE1) segment so we don't match the embedded thumbnail's SOF marker inside EXIF payload
        if (marker == 0xE1) {
            idx += seg_len;
            continue;
        }

        if ((marker >= 0xC0 and marker <= 0xC3) or
            (marker >= 0xC5 and marker <= 0xC7) or
            (marker >= 0xC9 and marker <= 0xCB) or
            (marker >= 0xCD and marker <= 0xCF))
        {
            if (idx + 7 <= data.len) {
                const h = (@as(u16, data[idx + 3]) << 8) | @as(u16, data[idx + 4]);
                const w = (@as(u16, data[idx + 5]) << 8) | @as(u16, data[idx + 6]);
                if (w > 0 and h > 0) {
                    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
                }
            }
        }

        idx += seg_len;
    }
    return null;
}

pub fn parseExifOrientation(data: []const u8) ?Orientation {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    var entry_off = ifd0_off + 2;

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (entry_off + 12 > tiff.len) break;
        const entry = tiff[entry_off .. entry_off + 12];
        entry_off += 12;

        const tag = if (is_le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
        if (tag == 0x0112) {
            const val = if (is_le) std.mem.readInt(u16, entry[8..10][0..2], .little) else std.mem.readInt(u16, entry[8..10][0..2], .big);
            return Orientation.fromTiff(val);
        }
    }
    return null;
}

pub fn readJpegExifOrientation(io: std.Io, path: []const u8) ?Orientation {
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".jpg") and !std.ascii.eqlIgnoreCase(ext, ".jpeg")) return null;

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        std.log.debug("readJpegExifOrientation: openFile failed for '{s}': {}", .{ path, err });
        return null;
    };
    defer file.close(io);

    var buf: [65536]u8 = undefined;
    var slices = [_][]u8{&buf};
    const n = file.readPositional(io, &slices, 0) catch |err| {
        std.log.debug("readJpegExifOrientation: readPositional failed for '{s}': {}", .{ path, err });
        return null;
    };
    return parseExifOrientation(buf[0..n]);
}

/// Byte offset and length of an embedded JPEG thumbnail inside an image file.
pub const ThumbnailLocation = struct {
    file_offset: u64,
    length: u32,
};

pub fn extractJpegThumbnailLocation(data: []const u8) ?ThumbnailLocation {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    const ifd1_ptr_off = ifd0_off + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 > tiff.len) return null;

    const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
    if (ifd1_off == 0 or ifd1_off >= tiff.len or ifd1_off + 2 > tiff.len) return null;

    const num_ifd1_entries = if (is_le) std.mem.readInt(u16, tiff[ifd1_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd1_off..][0..2], .big);
    var entry_off = ifd1_off + 2;

    var thumb_off: ?u32 = null;
    var thumb_len: ?u32 = null;

    var i: usize = 0;
    while (i < num_ifd1_entries) : (i += 1) {
        if (entry_off + 12 > tiff.len) break;
        const entry = tiff[entry_off .. entry_off + 12];
        entry_off += 12;

        const tag = if (is_le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
        if (tag == 0x0201) {
            thumb_off = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
        } else if (tag == 0x0202) {
            thumb_len = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
        }
    }

    if (thumb_off != null and thumb_len != null) {
        const tiff_start_off = @intFromPtr(tiff.ptr) - @intFromPtr(data.ptr);
        return .{
            .file_offset = tiff_start_off + @as(u64, thumb_off.?),
            .length = thumb_len.?,
        };
    }
    return null;
}

pub fn extractJpegThumbnail(data: []const u8) ?[]const u8 {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    const ifd1_ptr_off = ifd0_off + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 > tiff.len) return null;

    const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
    if (ifd1_off == 0 or ifd1_off >= tiff.len or ifd1_off + 2 > tiff.len) return null;

    const num_ifd1_entries = if (is_le) std.mem.readInt(u16, tiff[ifd1_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd1_off..][0..2], .big);
    var entry_off = ifd1_off + 2;

    var thumb_off: ?u32 = null;
    var thumb_len: ?u32 = null;

    var i: usize = 0;
    while (i < num_ifd1_entries) : (i += 1) {
        if (entry_off + 12 > tiff.len) break;
        const entry = tiff[entry_off .. entry_off + 12];
        entry_off += 12;

        const tag = if (is_le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
        if (tag == 0x0201) {
            thumb_off = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
        } else if (tag == 0x0202) {
            thumb_len = if (is_le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
        }
    }

    if (thumb_off != null and thumb_len != null) {
        const off = @as(usize, thumb_off.?);
        const len = @as(usize, thumb_len.?);
        if (off < tiff.len and off + len <= tiff.len) {
            return tiff[off .. off + len];
        }
    }
    return null;
}

test "parseExifOrientation" {
    // 1. Invalid JPEG header -> null
    try std.testing.expectEqual(@as(?Orientation, null), parseExifOrientation("not a jpeg file"));

    // 2. Little Endian EXIF with Orientation 6 (90 degrees)
    const le_exif = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'I', 'I', // Little Endian
        0x2A, 0x00, // Signature 42
        0x08, 0x00, 0x00, 0x00, // IFD0 Offset = 8
        0x01, 0x00, // 1 entry
        0x12, 0x01, // Tag 0x0112 (Orientation)
        0x03, 0x00, // Type SHORT
        0x01, 0x00, 0x00, 0x00, // Count 1
        0x06, 0x00, 0x00, 0x00, // Value 6 (90 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?Orientation, .rotate_90), parseExifOrientation(&le_exif));

    // 3. Big Endian EXIF with Orientation 8 (270 degrees)
    const be_exif = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'M', 'M', // Big Endian
        0x00, 0x2A, // Signature 42
        0x00, 0x00, 0x00, 0x08, // IFD0 Offset = 8
        0x00, 0x01, // 1 entry
        0x01, 0x12, // Tag 0x0112 (Orientation)
        0x00, 0x03, // Type SHORT
        0x00, 0x00, 0x00, 0x01, // Count 1
        0x00, 0x08, 0x00, 0x00, // Value 8 (270 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?Orientation, .rotate_270), parseExifOrientation(&be_exif));

    // 4. Big Endian EXIF with Orientation 3 (180 degrees)
    const be_exif_180 = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x1E, // Length = 30
        'E', 'x', 'i', 'f', 0x00, 0x00, // Header
        'M', 'M', // Big Endian
        0x00, 0x2A, // Signature 42
        0x00, 0x00, 0x00, 0x08, // IFD0 Offset = 8
        0x00, 0x01, // 1 entry
        0x01, 0x12, // Tag 0x0112 (Orientation)
        0x00, 0x03, // Type SHORT
        0x00, 0x00, 0x00, 0x01, // Count 1
        0x00, 0x03, 0x00, 0x00, // Value 3 (180 degrees)
        0x00, 0x00, 0x00, 0x00, // Next IFD
    };
    try std.testing.expectEqual(@as(?Orientation, .rotate_180), parseExifOrientation(&be_exif_180));
}

test "readJpegExifOrientation on non-jpeg file" {
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const rot = readJpegExifOrientation(io, "src/main.zig");
    try std.testing.expectEqual(@as(?Orientation, null), rot);
}

test "extractJpegThumbnail" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractJpegThumbnail("invalid data"));

    const dummy_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 };
    const exif_data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x44, // Length = 68
        'E', 'x', 'i', 'f', 0x00, 0x00, // Exif header
        'I', 'I', // Little Endian
        0x2A, 0x00, // Sig
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x01, 0x00, // IFD0 entries = 1
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // Orientation tag
        0x1A, 0x00, 0x00, 0x00, // IFD1 offset = 26 (relative to TIFF header start)
        0x02, 0x00, // IFD1 entries = 2
        0x01, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, // Tag 0x0201: Thumb offset = 56
        0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, // Tag 0x0202: Thumb len = 4
        0x00, 0x00, 0x00, 0x00, // Next IFD offset = 0
        0xFF, 0xD8, 0xFF, 0xD9, // Thumb payload at offset 56 in TIFF (68 in full buffer)
    };

    const thumb = extractJpegThumbnail(&exif_data);
    try std.testing.expect(thumb != null);
    try std.testing.expectEqualSlices(u8, &dummy_jpeg, thumb.?);
}

test "readJpegDimensions" {
    try std.testing.expectEqual(null, readJpegDimensions("invalid"));

    const jpeg_sof0 = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, // SOF0
        0x00, 0x0B, // Length = 11
        0x08, // Precision 8
        0x04, 0x00, // Height = 1024
        0x08, 0x00, // Width = 2048
        0x03, // Components
        0x01,
        0x11,
        0x00,
    };

    const dims = readJpegDimensions(&jpeg_sof0);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 2048.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 1024.0), dims.?.h);
}

test "parseExifDimensions" {
    const exif_dims_data = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, // APP1
        0x00, 0x2E, // Length = 46
        'E',  'x',
        'i',  'f',
        0x00, 0x00,
        'I', 'I', // Little Endian
        0x2A, 0x00, // Sig 42
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x02, 0x00, // 2 entries
        0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, // Tag 0x0100 = 7728
        0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x20, 0x14, 0x00, 0x00, // Tag 0x0101 = 5152
        0x00, 0x00, 0x00, 0x00,
    };

    const dims = parseExifDimensions(&exif_dims_data);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 7728.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 5152.0), dims.?.h);
}
