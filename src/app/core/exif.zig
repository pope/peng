const state_pkg = @import("state");
const std = @import("std");

const Orientation = state_pkg.Orientation;

/// Floating-point dimensions (width and height) of a JPEG image in pixels.
pub const JpegDimensions = struct { w: f32, h: f32 };

/// Parsed TIFF payload header located within an APP1 EXIF segment.
const TiffHeader = struct {
    tiff: []const u8,
    is_le: bool,
    ifd0_off: u32,
};

inline fn readU16(bytes: *const [2]u8, is_le: bool) u16 {
    return std.mem.readInt(u16, bytes, if (is_le) .little else .big);
}

inline fn readU32(bytes: *const [4]u8, is_le: bool) u32 {
    return std.mem.readInt(u32, bytes, if (is_le) .little else .big);
}

/// Canonical TIFF tag IDs per TIFF 6.0, TIFF-EP (ISO 12234-2), EXIF 2.32, and Adobe DNG specifications.
pub const TiffTag = enum(u16) {
    new_subfile_type = 0x00FE,
    image_width = 0x0100,
    image_length = 0x0101,
    bits_per_sample = 0x0102,
    compression = 0x0103,
    photometric_interpretation = 0x0106,
    strip_offsets = 0x0111,
    orientation = 0x0112,
    samples_per_pixel = 0x0115,
    strip_byte_counts = 0x0117,
    planar_configuration = 0x011C,
    sub_ifds = 0x014A,
    jpeg_interchange_format = 0x0201,
    jpeg_interchange_format_length = 0x0202,
    exif_ifd = 0x8769,
    pixel_x_dimension = 0xA002,
    pixel_y_dimension = 0xA003,
    cr2_slice = 0xC5D8,
    cr2_raw_image_data = 0xC5D9,
    cr2_sensor_info = 0xC5E0,
    cr2_offsets = 0xC640,
    dng_private_data = 0xC634,
    _,

    pub inline fn fromInt(val: u16) TiffTag {
        return @enumFromInt(val);
    }
};

/// Bitflags for TIFF tag 0x00FE (`NewSubfileType`).
/// Defined in TIFF 6.0 Section 6 (p. 36) and Adobe DNG Specification Section 2.
pub const NewSubfileType = struct {
    /// Primary full-resolution image (raw Bayer sensor CFA array in RAW containers).
    pub const FULL_RESOLUTION: u32 = 0x00000000;
    /// Reduced-resolution version of another image in this file (thumbnail or medium preview).
    pub const REDUCED_IMAGE: u32 = 0x00000001;
    /// Multi-page document page.
    pub const PAGE: u32 = 0x00000002;
    /// Transparency / alpha mask.
    pub const MASK: u32 = 0x00000004;
    /// Alternative processed preview image (Adobe DNG 1.2+).
    pub const PREVIEW_IMAGE: u32 = 0x00010000;

    /// Checks if this subfile represents a reduced-resolution preview or thumbnail.
    pub inline fn isReducedImage(val: u32) bool {
        return (val & REDUCED_IMAGE) != 0;
    }
};

/// PhotometricInterpretation values per TIFF 6.0 and TIFF-EP.
pub const Photometric = enum(u16) {
    black_is_zero = 1,
    rgb = 2,
    ycbcr = 6,
    cfa = 32803,
    linear_raw = 34892,
    _,
};

/// Compression values per TIFF 6.0 and TIFF-EP.
pub const Compression = enum(u16) {
    uncompressed = 1,
    jpeg_old = 6,
    jpeg = 7,
    sony_arw = 32767,
    _,
};

/// Segmented TIFF source for zero-allocation parsing of files where the root IFD0
/// directory is located at the tail of the file rather than the initial header.
pub const TiffSource = struct {
    header: []const u8,
    tail_offset: u64 = 0,
    tail: []const u8 = "",

    pub inline fn init(header: []const u8) TiffSource {
        return .{ .header = header };
    }

    pub inline fn initWithTail(
        header: []const u8,
        tail_offset: u64,
        tail: []const u8,
    ) TiffSource {
        return .{
            .header = header,
            .tail_offset = tail_offset,
            .tail = tail,
        };
    }

    pub inline fn getSlice(self: TiffSource, off: usize, len: usize) ?[]const u8 {
        if (std.math.add(usize, off, len)) |end| {
            if (end <= self.header.len) {
                return self.header[off..end];
            }
        } else |_| {}

        if (self.tail.len > 0 and off >= self.tail_offset) {
            const rel_u64 = off - self.tail_offset;
            if (rel_u64 <= self.tail.len) {
                const rel: usize = @intCast(rel_u64);
                if (std.math.add(usize, rel, len)) |tail_end| {
                    if (tail_end <= self.tail.len) {
                        return self.tail[rel..tail_end];
                    }
                } else |_| {}
            }
        }
        return null;
    }
};

/// Probes the 8-byte TIFF container header to extract the root IFD0 offset
/// without reading or parsing tags.
pub fn probeTiffIfd0Offset(header: []const u8) ?u32 {
    if (header.len < 8) return null;
    const is_le = if (std.mem.eql(u8, header[0..2], "II"))
        true
    else if (std.mem.eql(u8, header[0..2], "MM"))
        false
    else
        return null;
    const sig = readU16(header[2..4][0..2], is_le);
    if (sig != 0x002A) return null;
    const ifd0_off = readU32(header[4..8][0..4], is_le);
    if (ifd0_off < 8 or (ifd0_off & 1) != 0) return null;
    return ifd0_off;
}

/// Probes and streams tail IFD0 into tail_buf when located beyond header_slice.
/// Returns a TiffSource referencing either header alone or header + tail.
pub fn readTiffSource(
    io: std.Io,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
    tail_buf: []u8,
) TiffSource {
    if (probeTiffIfd0Offset(header_slice)) |ifd0_off| {
        if (ifd0_off >= header_slice.len and ifd0_off < file_size) {
            const tail_target: usize = @intCast(@min(file_size - ifd0_off, tail_buf.len));
            if (tail_target > 0) {
                var t_slices = [_][]u8{tail_buf[0..tail_target]};
                const tn = file.readPositional(io, &t_slices, ifd0_off) catch 0;
                if (tn > 0) {
                    return TiffSource.initWithTail(header_slice, ifd0_off, tail_buf[0..tn]);
                }
            }
        }
    }
    return TiffSource.init(header_slice);
}

const TiffHeaderSource = struct {
    source: TiffSource,
    is_le: bool,
    ifd0_off: u32,
    tiff_start_off: u64 = 0,
};

fn findTiffPayloadFromSource(source: TiffSource) ?TiffHeaderSource {
    // 1. Direct TIFF container (Sony ARW, DNG, CR2, NEF, ORF, RW2, PEF, etc.)
    if (source.getSlice(0, 8)) |h8| {
        if (std.mem.eql(u8, h8[0..2], "II") or std.mem.eql(u8, h8[0..2], "MM")) {
            const is_le = (h8[0] == 'I');
            const sig = readU16(h8[2..4][0..2], is_le);
            if (sig == 0x002A) {
                const ifd0_off = readU32(h8[4..8][0..4], is_le);
                const off: usize = ifd0_off;
                if (off >= 8 and (off & 1) == 0 and source.getSlice(off, 2) != null) {
                    return .{
                        .source = source,
                        .is_le = is_le,
                        .ifd0_off = ifd0_off,
                        .tiff_start_off = 0,
                    };
                }
            }
        }
    }

    // 2. JPEG APP1 EXIF segment
    if (source.header.len < 14) return null;
    if (source.header[0] != 0xFF or source.header[1] != 0xD8) return null;

    var idx: usize = 2;
    while (idx + 4 <= source.header.len) {
        if (source.header[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < source.header.len and source.header[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= source.header.len) break;
        const marker = source.header[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > source.header.len) break;
        const seg_len = (@as(usize, source.header[idx]) << 8) | @as(usize, source.header[idx + 1]);
        if (seg_len < 2) break;

        const available_len = @min(seg_len, source.header.len - idx);
        const payload = source.header[idx + 2 .. idx + available_len];

        if (marker == 0xE1) {
            if (payload.len >= 14 and std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
                const tiff = payload[6..];
                if (tiff.len >= 8) {
                    const is_le = if (std.mem.eql(u8, tiff[0..2], "II"))
                        true
                    else if (std.mem.eql(u8, tiff[0..2], "MM"))
                        false
                    else
                        continue;

                    const sig = readU16(tiff[2..4][0..2], is_le);
                    if (sig == 0x002A) {
                        const ifd0_off = readU32(tiff[4..8][0..4], is_le);
                        const off: usize = ifd0_off;
                        if (off >= 8 and (off & 1) == 0 and off + 2 <= tiff.len) {
                            const tiff_start_off: u64 =
                                @intFromPtr(tiff.ptr) - @intFromPtr(source.header.ptr);
                            return .{
                                .source = TiffSource.init(tiff),
                                .is_le = is_le,
                                .ifd0_off = ifd0_off,
                                .tiff_start_off = tiff_start_off,
                            };
                        }
                    }
                }
            }
        }

        if (idx + seg_len > source.header.len) break;
        idx += seg_len;
    }
    return null;
}

fn findTiffPayload(data: []const u8) ?TiffHeader {
    // 1. Direct TIFF container (Sony ARW, DNG, CR2, NEF, ORF, RW2, PEF, etc.)
    if (data.len >= 8) {
        if (std.mem.eql(u8, data[0..2], "II") or std.mem.eql(u8, data[0..2], "MM")) {
            const is_le = (data[0] == 'I');
            const sig = readU16(data[2..4][0..2], is_le);
            if (sig == 0x002A) {
                const ifd0_off = readU32(data[4..8][0..4], is_le);
                const off: usize = ifd0_off;
                if (off >= 8 and (off & 1) == 0 and off + 2 <= data.len) {
                    return .{
                        .tiff = data,
                        .is_le = is_le,
                        .ifd0_off = ifd0_off,
                    };
                }
            }
        }
    }

    // 2. JPEG APP1 EXIF segment
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
        if (seg_len < 2) break;

        const available_len = @min(seg_len, data.len - idx);
        const payload = data[idx + 2 .. idx + available_len];

        if (marker == 0xE1) {
            if (payload.len >= 14 and std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
                const tiff = payload[6..];
                if (tiff.len >= 8) {
                    const is_le = if (std.mem.eql(u8, tiff[0..2], "II"))
                        true
                    else if (std.mem.eql(u8, tiff[0..2], "MM"))
                        false
                    else
                        continue;

                    const sig = readU16(tiff[2..4][0..2], is_le);
                    if (sig == 0x002A) {
                        const ifd0_off = readU32(tiff[4..8][0..4], is_le);
                        const off: usize = ifd0_off;
                        if (off >= 8 and (off & 1) == 0 and off + 2 <= tiff.len) {
                            return .{
                                .tiff = tiff,
                                .is_le = is_le,
                                .ifd0_off = ifd0_off,
                            };
                        }
                    }
                }
            }
        }

        if (idx + seg_len > data.len) break;
        idx += seg_len;
    }
    return null;
}

const SubIfdList = struct {
    items: [8]u32 = undefined,
    len: usize = 0,

    pub fn append(self: *SubIfdList, item: u32) void {
        if (self.len < self.items.len) {
            self.items[self.len] = item;
            self.len += 1;
        }
    }

    pub fn slice(self: *const SubIfdList) []const u32 {
        return self.items[0..self.len];
    }
};

/// Parses image pixel dimensions from EXIF TIFF metadata tags (IFD0, ExifIFD, or SubIFD).
pub fn parseExifDimensions(data: []const u8) ?JpegDimensions {
    return parseExifDimensionsFromSource(TiffSource.init(data));
}

/// Parses image pixel dimensions from a segmented TiffSource.
pub fn parseExifDimensionsFromSource(source: TiffSource) ?JpegDimensions {
    const header = findTiffPayloadFromSource(source) orelse return null;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;
    const src = header.source;

    // Detect Canon CR2 container signature at bytes 8..12 ("CR\x02\x00")
    const is_cr2 = blk: {
        const sig = src.getSlice(8, 4) orelse break :blk false;
        break :blk sig[0] == 'C' and sig[1] == 'R' and
            sig[2] == 0x02 and sig[3] == 0x00;
    };

    var best_w: ?u32 = null;
    var best_h: ?u32 = null;
    var best_area: u64 = 0;
    var exif_sub_ifd_off: ?u32 = null;
    var sub_ifd_list: SubIfdList = .{};

    const parseIfd = struct {
        fn run(
            s: TiffSource,
            off: usize,
            le: bool,
            b_w: *?u32,
            b_h: *?u32,
            b_area: *u64,
            sub_out: ?*?u32,
            sub_ifds: ?*SubIfdList,
            is_cr2_file: bool,
            depth: usize,
        ) u32 {
            if (off < 8 or (off & 1) != 0) return 0;
            const num_bytes = s.getSlice(off, 2) orelse return 0;
            const num = readU16(num_bytes[0..2], le);
            var entry_off = off + 2;
            var i: usize = 0;
            var cur_w: ?u32 = null;
            var cur_h: ?u32 = null;
            var subfile_type: ?u32 = null;
            var photometric: ?u16 = null;

            while (i < num) : (i += 1) {
                const entry = s.getSlice(entry_off, 12) orelse break;
                entry_off += 12;

                const tag = readU16(entry[0..2][0..2], le);
                const type_id = readU16(entry[2..4][0..2], le);
                const count = readU32(entry[4..8][0..4], le);

                var val: u32 = 0;
                if (type_id == 3) {
                    val = readU16(entry[8..10][0..2], le);
                } else if (type_id == 4 or type_id == 13) {
                    val = readU32(entry[8..12][0..4], le);
                }

                if (tag == @intFromEnum(TiffTag.new_subfile_type)) {
                    subfile_type = val;
                } else if (tag == @intFromEnum(TiffTag.photometric_interpretation)) {
                    photometric = @intCast(val);
                } else if (tag == @intFromEnum(TiffTag.image_width) or
                    tag == @intFromEnum(TiffTag.pixel_x_dimension))
                {
                    cur_w = val;
                } else if (tag == @intFromEnum(TiffTag.image_length) or
                    tag == @intFromEnum(TiffTag.pixel_y_dimension))
                {
                    cur_h = val;
                } else if (tag == @intFromEnum(TiffTag.exif_ifd) and sub_out != null) {
                    sub_out.?.* = val;
                } else if (tag == @intFromEnum(TiffTag.sub_ifds) and sub_ifds != null) {
                    if (count == 1) {
                        if (val > 0) sub_ifds.?.append(val);
                    } else if (count > 1 and (type_id == 4 or type_id == 13)) {
                        const fetch_count = @min(count, 8);
                        var s_idx: usize = 0;
                        while (s_idx < fetch_count) : (s_idx += 1) {
                            if (std.math.add(usize, @as(usize, val), s_idx * 4)) |read_pos| {
                                if (s.getSlice(read_pos, 4)) |s_slice| {
                                    const s_off = readU32(s_slice[0..4], le);
                                    if (s_off > 0) sub_ifds.?.append(s_off);
                                }
                            } else |_| break;
                        }
                    }
                }
            }

            // Reject raw Bayer sensor streams:
            // 1. CFA Bayer (32803) or LinearRaw (34892)
            // 2. Primary raw sensor SubIFDs (!isReducedImage inside SubIFD)
            // 3. Canon CR2 IFD2/IFD3 raw sensor slices
            const is_raw_cfa = (photometric != null and
                (photometric.? == @intFromEnum(Photometric.cfa) or
                    photometric.? == @intFromEnum(Photometric.linear_raw)));
            const is_subifd_raw = (sub_ifds == null and subfile_type != null and
                !NewSubfileType.isReducedImage(subfile_type.?));
            const is_cr2_raw = (is_cr2_file and depth >= 2);
            if (!is_raw_cfa and !is_subifd_raw and !is_cr2_raw) {
                if (cur_w != null and cur_h != null) {
                    const area = @as(u64, cur_w.?) * @as(u64, cur_h.?);
                    if (area > b_area.*) {
                        b_area.* = area;
                        b_w.* = cur_w;
                        b_h.* = cur_h;
                    }
                }
            }

            if (i < num) return 0;
            if (s.getSlice(entry_off, 4)) |next_slice| {
                return readU32(next_slice[0..4], le);
            }
            return 0;
        }
    }.run;

    var cur_ifd_off: u32 = ifd0_off;
    var ifd_depth: usize = 0;
    var visited: [8]u32 = undefined;
    while (cur_ifd_off > 0 and ifd_depth < 8) : (ifd_depth += 1) {
        var is_cycle = false;
        for (visited[0..ifd_depth]) |v| {
            if (v == cur_ifd_off) {
                is_cycle = true;
                break;
            }
        }
        if (is_cycle) break;
        visited[ifd_depth] = cur_ifd_off;

        const next_off = parseIfd(
            src,
            cur_ifd_off,
            is_le,
            &best_w,
            &best_h,
            &best_area,
            if (ifd_depth == 0) &exif_sub_ifd_off else null,
            if (ifd_depth == 0) &sub_ifd_list else null,
            is_cr2,
            ifd_depth,
        );
        cur_ifd_off = next_off;
    }

    if (exif_sub_ifd_off) |sub_off| {
        _ = parseIfd(
            src,
            sub_off,
            is_le,
            &best_w,
            &best_h,
            &best_area,
            null,
            null,
            is_cr2,
            1,
        );
    }

    for (sub_ifd_list.slice()) |s_off| {
        _ = parseIfd(
            src,
            s_off,
            is_le,
            &best_w,
            &best_h,
            &best_area,
            null,
            null,
            is_cr2,
            1,
        );
    }

    if (best_w != null and best_h != null) {
        return JpegDimensions{ .w = @floatFromInt(best_w.?), .h = @floatFromInt(best_h.?) };
    }
    return null;
}

/// Reads image dimensions from EXIF metadata or scans JPEG Start-of-Frame (SOF) markers.
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

        // Skip APP1 (0xE1) segment so we don't match the embedded thumbnail's
        // SOF marker inside EXIF payload
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

/// Inspects a JPEG bitstream header for Lossless Huffman (SOF3 / 0xC3) markers
/// used for raw Bayer sensor data in camera RAW files (such as Canon CR2).
pub fn isLosslessJpeg(data: []const u8) bool {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return false;
    var idx: usize = 2;
    while (idx + 1 < data.len) {
        if (data[idx] != 0xFF) break;
        var marker_offset = idx + 1;
        while (marker_offset < data.len and data[marker_offset] == 0xFF) {
            marker_offset += 1;
        }
        if (marker_offset >= data.len) break;
        const marker = data[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0x00 or marker == 0xD9 or marker == 0xDA) break;
        if (marker == 0xC3) return true;
        if (marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD7)) continue;

        if (idx + 2 > data.len) break;
        const seg_len = (@as(usize, data[idx]) << 8) | @as(usize, data[idx + 1]);
        if (seg_len < 2 or seg_len > data.len - idx) break;

        idx += seg_len;
    }
    return false;
}

/// Extracts the TIFF orientation tag (0x0112) from an EXIF payload.
pub fn parseExifOrientation(data: []const u8) ?Orientation {
    return parseExifOrientationFromSource(TiffSource.init(data));
}

/// Extracts the TIFF orientation tag (0x0112) from a segmented TiffSource.
pub fn parseExifOrientationFromSource(source: TiffSource) ?Orientation {
    const header = findTiffPayloadFromSource(source) orelse return null;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;
    const src = header.source;

    const num_bytes = src.getSlice(ifd0_off, 2) orelse return null;
    const num_entries = readU16(num_bytes[0..2], is_le);
    var entry_off = ifd0_off + 2;

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        const entry = src.getSlice(entry_off, 12) orelse break;
        entry_off += 12;

        const tag = readU16(entry[0..2][0..2], is_le);
        if (tag == @intFromEnum(TiffTag.orientation)) {
            const val = readU16(entry[8..10][0..2], is_le);
            return Orientation.fromTiff(val);
        }
    }
    return null;
}

/// Reads the EXIF orientation tag by reading the header of a JPEG file on disk.
pub fn readJpegExifOrientation(io: std.Io, path: []const u8) ?Orientation {
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".jpg") and
        !std.ascii.eqlIgnoreCase(ext, ".jpeg")) return null;

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        std.log.debug("readJpegExifOrientation: openFile failed for '{s}': {}", .{ path, err });
        return null;
    };
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var slices = [_][]u8{&buf};
    const n = file.readPositional(io, &slices, 0) catch |err| {
        std.log.debug(
            "readJpegExifOrientation: readPositional failed for '{s}': {}",
            .{ path, err },
        );
        return null;
    };
    return parseExifOrientation(buf[0..n]);
}

/// Byte offset and length of an embedded JPEG thumbnail inside an image file.
pub const ThumbnailLocation = struct {
    file_offset: u64,
    length: u32,
};

/// Locates the byte offset and length of an embedded JPEG thumbnail in IFD1
/// without allocating memory.
pub fn extractJpegThumbnailLocation(data: []const u8) ?ThumbnailLocation {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = readU16(tiff[ifd0_off..][0..2], is_le);
    const ifd1_ptr_off = @as(usize, ifd0_off) + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 > tiff.len) return null;

    const ifd1_off = readU32(tiff[ifd1_ptr_off..][0..4], is_le);
    const ifd1_usize: usize = ifd1_off;
    if (ifd1_usize == 0 or ifd1_usize + 2 > tiff.len) return null;

    const num_ifd1_entries = readU16(tiff[ifd1_usize..][0..2], is_le);
    var entry_off = ifd1_usize + 2;

    var thumb_off: ?u32 = null;
    var thumb_len: ?u32 = null;

    var i: usize = 0;
    while (i < num_ifd1_entries) : (i += 1) {
        if (entry_off + 12 > tiff.len) break;
        const entry = tiff[entry_off .. entry_off + 12];
        entry_off += 12;

        const tag = readU16(entry[0..2][0..2], is_le);
        if (tag == @intFromEnum(TiffTag.jpeg_interchange_format)) {
            thumb_off = readU32(entry[8..12][0..4], is_le);
        } else if (tag == @intFromEnum(TiffTag.jpeg_interchange_format_length)) {
            thumb_len = readU32(entry[8..12][0..4], is_le);
        }
    }

    if (thumb_off != null and thumb_len != null and thumb_len.? > 0) {
        const tiff_start_off = @intFromPtr(tiff.ptr) - @intFromPtr(data.ptr);
        return .{
            .file_offset = tiff_start_off + @as(u64, thumb_off.?),
            .length = thumb_len.?,
        };
    }
    return null;
}

/// Set of extracted preview, medium-res preview, and thumbnail locations from a RAW container.
pub const RawPreviewCandidates = struct {
    preview: ?ThumbnailLocation = null,
    medium: ?ThumbnailLocation = null,
    thumbnail: ?ThumbnailLocation = null,
};

/// Extracts the largest embedded JPEG preview location and smallest thumbnail
/// location from a TIFF-based RAW container.
pub fn extractTiffRawPreviews(data: []const u8) RawPreviewCandidates {
    return extractTiffRawPreviewsFromSource(TiffSource.init(data));
}

/// Extracts the largest embedded JPEG preview location and smallest thumbnail
/// location from a segmented TiffSource.
pub fn extractTiffRawPreviewsFromSource(source: TiffSource) RawPreviewCandidates {
    const header = findTiffPayloadFromSource(source) orelse return .{};
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;
    const tiff_start_off = header.tiff_start_off;
    const src = header.source;

    // Detect Canon CR2 container signature at bytes 8..12 ("CR\x02\x00")
    const is_cr2 = blk: {
        const sig = src.getSlice(8, 4) orelse break :blk false;
        break :blk sig[0] == 'C' and sig[1] == 'R' and
            sig[2] == 0x02 and sig[3] == 0x00;
    };

    const Candidate = struct { off: u32, len: u32 };
    var candidates: [16]Candidate = undefined;
    var cand_count: usize = 0;

    const parseIfdForJpegs = struct {
        fn run(
            s: TiffSource,
            off: usize,
            le: bool,
            cands: []Candidate,
            count: *usize,
            sub_ifds: ?*SubIfdList,
            is_cr2_file: bool,
            depth: usize,
        ) u32 {
            if (off < 8 or (off & 1) != 0) return 0;
            const num_bytes = s.getSlice(off, 2) orelse return 0;
            const num = readU16(num_bytes[0..2], le);
            var entry_off = off + 2;
            var i: usize = 0;
            var j_off: ?u32 = null;
            var j_len: ?u32 = null;
            var compression: ?u16 = null;
            var photometric: ?u16 = null;
            var subfile_type: ?u32 = null;
            var strip_off: ?u32 = null;
            var strip_len: ?u32 = null;
            var planar_config: ?u16 = null;
            var is_cr2_raw_ifd = false;

            while (i < num) : (i += 1) {
                const entry = s.getSlice(entry_off, 12) orelse break;
                entry_off += 12;

                const tag = readU16(entry[0..2][0..2], le);
                const type_id = readU16(entry[2..4][0..2], le);
                const val_count = readU32(entry[4..8][0..4], le);

                if (tag == @intFromEnum(TiffTag.new_subfile_type)) {
                    subfile_type = if (type_id == 3)
                        readU16(entry[8..10][0..2], le)
                    else
                        readU32(entry[8..12][0..4], le);
                } else if (tag == @intFromEnum(TiffTag.compression)) {
                    compression = readU16(entry[8..10][0..2], le);
                } else if (tag == @intFromEnum(TiffTag.photometric_interpretation)) {
                    photometric = readU16(entry[8..10][0..2], le);
                } else if (tag == @intFromEnum(TiffTag.planar_configuration)) {
                    planar_config = readU16(entry[8..10][0..2], le);
                } else if (tag == @intFromEnum(TiffTag.cr2_slice) or
                    tag == @intFromEnum(TiffTag.cr2_raw_image_data) or
                    tag == @intFromEnum(TiffTag.cr2_sensor_info) or
                    tag == @intFromEnum(TiffTag.cr2_offsets))
                {
                    is_cr2_raw_ifd = true;
                } else if (tag == @intFromEnum(TiffTag.strip_offsets)) {
                    // Per DNG Spec / TIFF-EP, embedded JPEG previews must be a
                    // single contiguous bitstream
                    if (val_count == 1) {
                        strip_off = if (type_id == 3)
                            readU16(entry[8..10][0..2], le)
                        else
                            readU32(entry[8..12][0..4], le);
                    }
                } else if (tag == @intFromEnum(TiffTag.strip_byte_counts)) {
                    if (val_count == 1) {
                        strip_len = if (type_id == 3)
                            readU16(entry[8..10][0..2], le)
                        else
                            readU32(entry[8..12][0..4], le);
                    }
                } else if (tag == @intFromEnum(TiffTag.jpeg_interchange_format)) {
                    j_off = readU32(entry[8..12][0..4], le);
                } else if (tag == @intFromEnum(TiffTag.jpeg_interchange_format_length)) {
                    j_len = readU32(entry[8..12][0..4], le);
                } else if (tag == @intFromEnum(TiffTag.dng_private_data)) {
                    const val_or_off = readU32(entry[8..12][0..4], le);
                    if (val_count >= 70) {
                        if (s.getSlice(val_or_off, 70)) |p_slice| {
                            if (std.mem.startsWith(u8, p_slice, "RICOH\x00II") or
                                std.mem.startsWith(u8, p_slice, "PENTAX\x00II"))
                            {
                                // MakerNote explicitly asserts "II" (Little Endian)
                                const p_len =
                                    std.mem.readInt(u32, p_slice[54..58][0..4], .little);
                                const p_rel_off =
                                    std.mem.readInt(u32, p_slice[66..70][0..4], .little);
                                if (p_len > 0 and p_len < 512 * 1024 and
                                    @as(u64, p_rel_off) + p_len <= val_count)
                                {
                                    if (std.math.add(u32, val_or_off, p_rel_off)) |mn_jpeg_off| {
                                        if (count.* < cands.len) {
                                            cands[count.*] = .{ .off = mn_jpeg_off, .len = p_len };
                                            count.* += 1;
                                        }
                                    } else |_| {}
                                }
                            }
                        }
                    }
                } else if (tag == @intFromEnum(TiffTag.sub_ifds) and sub_ifds != null) {
                    if (val_count == 1) {
                        const s_off = readU32(entry[8..12][0..4], le);
                        if (s_off > 0) sub_ifds.?.append(s_off);
                    } else if (val_count > 1 and (type_id == 4 or type_id == 13)) {
                        const fetch_count = @min(val_count, 8);
                        const ptr_off = readU32(entry[8..12][0..4], le);
                        var s_idx: usize = 0;
                        while (s_idx < fetch_count) : (s_idx += 1) {
                            if (std.math.add(usize, @as(usize, ptr_off), s_idx * 4)) |read_pos| {
                                if (s.getSlice(read_pos, 4)) |sub_bytes| {
                                    const s_off = readU32(sub_bytes[0..4], le);
                                    if (s_off > 0) sub_ifds.?.append(s_off);
                                }
                            } else |_| break;
                        }
                    }
                }
            }

            if (j_off != null and j_len != null and j_off.? > 0 and j_len.? > 0) {
                if (!is_cr2_file or depth < 2) {
                    if (count.* < cands.len) {
                        cands[count.*] = .{ .off = j_off.?, .len = j_len.? };
                        count.* += 1;
                    }
                }
            } else if (strip_off != null and strip_len != null and
                strip_off.? > 0 and strip_len.? > 0)
            {
                // Support standard TIFF JPEG compression (6 = OJPEG, 7 = JPEG)
                const is_jpeg_comp = (compression != null and
                    (compression.? == @intFromEnum(Compression.jpeg_old) or
                        compression.? == @intFromEnum(Compression.jpeg)));
                // Standard JPEG preview photometrics (6 = YCbCr, 2 = RGB,
                // 1 = BlackIsZero, or null).
                // Specifically excludes 32803 (CFA Bayer) and 34892 (LinearRaw).
                const is_jpeg_color = (photometric == null or
                    photometric.? == @intFromEnum(Photometric.ycbcr) or
                    photometric.? == @intFromEnum(Photometric.rgb) or
                    photometric.? == @intFromEnum(Photometric.black_is_zero));
                const is_bayer_color = (photometric != null and
                    (photometric.? == @intFromEnum(Photometric.cfa) or
                        photometric.? == @intFromEnum(Photometric.linear_raw)));
                // Reject full-resolution primary raw sensor streams (NewSubfileType == 0)
                const is_reduced_or_unspecified = (subfile_type == null or
                    NewSubfileType.isReducedImage(subfile_type.?));

                var is_not_jpeg = false;
                var is_lossless_raw = false;

                // In Canon CR2, IFD2 is uncompressed RGB and IFD3 is Bayer raw sensor stream
                if (is_cr2_file and depth >= 2) is_not_jpeg = true;
                if (is_cr2_raw_ifd) is_not_jpeg = true;
                // Reject planar TIFFs (PlanarConfiguration == 2); JPEG strips are always chunky (1)
                if (planar_config != null and planar_config.? == 2) is_not_jpeg = true;

                // Validate SOI marker if strip payload header is accessible in source
                if (s.getSlice(strip_off.?, 2)) |soi| {
                    if (soi[0] != 0xFF or soi[1] != 0xD8) {
                        is_not_jpeg = true;
                    }
                }

                // Reject Lossless JPEG SOF3 (FF C3) raw Bayer sensor streams
                const inspect_len = @min(@as(usize, strip_len.?), 1024);
                if (s.getSlice(strip_off.?, inspect_len)) |p_hdr| {
                    if (isLosslessJpeg(p_hdr)) {
                        is_lossless_raw = true;
                    }
                } else if (s.getSlice(strip_off.?, 4)) |magic| {
                    if (magic[0] == 0xFF and magic[1] == 0xD8 and
                        magic[2] == 0xFF and magic[3] == 0xC3)
                    {
                        is_lossless_raw = true;
                    }
                }

                if (is_jpeg_comp and is_jpeg_color and !is_bayer_color and
                    is_reduced_or_unspecified and !is_not_jpeg and !is_lossless_raw)
                {
                    if (std.math.add(u32, strip_off.?, strip_len.?)) |_| {
                        if (count.* < cands.len) {
                            cands[count.*] = .{ .off = strip_off.?, .len = strip_len.? };
                            count.* += 1;
                        }
                    } else |_| {}
                }
            }

            if (i < num) return 0;
            if (s.getSlice(entry_off, 4)) |next_bytes| {
                return readU32(next_bytes[0..4], le);
            }
            return 0;
        }
    }.run;

    var sub_ifd_list: SubIfdList = .{};

    // 1. Follow IFD chain: IFD0 -> IFD1 -> IFD2 -> ...
    var cur_ifd_off: u32 = ifd0_off;
    var ifd_depth: usize = 0;
    var visited: [8]u32 = undefined;
    while (cur_ifd_off > 0 and ifd_depth < 8) : (ifd_depth += 1) {
        var is_cycle = false;
        for (visited[0..ifd_depth]) |v| {
            if (v == cur_ifd_off) {
                is_cycle = true;
                break;
            }
        }
        if (is_cycle) break;
        visited[ifd_depth] = cur_ifd_off;

        const next_ifd_off = parseIfdForJpegs(
            src,
            cur_ifd_off,
            is_le,
            &candidates,
            &cand_count,
            if (ifd_depth == 0) &sub_ifd_list else null,
            is_cr2,
            ifd_depth,
        );
        cur_ifd_off = next_ifd_off;
    }

    // 2. Parse SubIFDs discovered in IFD0
    for (sub_ifd_list.slice()) |s_off| {
        _ = parseIfdForJpegs(
            src,
            s_off,
            is_le,
            &candidates,
            &cand_count,
            null,
            is_cr2,
            1,
        );
    }

    if (cand_count == 0) return .{};

    var best_preview_idx: usize = 0;
    var best_thumb_idx: usize = 0;

    for (candidates[0..cand_count], 0..) |c, idx| {
        if (c.len > candidates[best_preview_idx].len) best_preview_idx = idx;
        if (c.len < candidates[best_thumb_idx].len) best_thumb_idx = idx;
    }

    const prev_c = candidates[best_preview_idx];
    const thumb_c = candidates[best_thumb_idx];

    var best_med_idx: ?usize = null;
    if (prev_c.len > thumb_c.len) {
        for (candidates[0..cand_count], 0..) |c, idx| {
            if (idx == best_preview_idx or idx == best_thumb_idx) continue;
            if (c.len > thumb_c.len and c.len < prev_c.len and c.len <= 2 * 1024 * 1024) {
                if (best_med_idx) |m_idx| {
                    if (c.len > candidates[m_idx].len) best_med_idx = idx;
                } else {
                    best_med_idx = idx;
                }
            }
        }
    }

    return .{
        .preview = .{
            .file_offset = tiff_start_off + @as(u64, prev_c.off),
            .length = prev_c.len,
        },
        .medium = if (best_med_idx) |m_idx| .{
            .file_offset = tiff_start_off + @as(u64, candidates[m_idx].off),
            .length = candidates[m_idx].len,
        } else null,
        .thumbnail = if (thumb_c.len <= 512 * 1024) .{
            .file_offset = tiff_start_off + @as(u64, thumb_c.off),
            .length = thumb_c.len,
        } else null,
    };
}

/// Reads the embedded preview JPEG byte offset and length from a Fujifilm RAF file header.
pub fn extractFujiRafPreviewLocation(header_bytes: []const u8) ?ThumbnailLocation {
    if (header_bytes.len < 92) return null;
    if (!std.mem.startsWith(u8, header_bytes, "FUJIFILM")) return null;
    const off = std.mem.readInt(u32, header_bytes[84..88], .big);
    const len = std.mem.readInt(u32, header_bytes[88..92], .big);
    if (off == 0 or len == 0) return null;
    return .{
        .file_offset = off,
        .length = len,
    };
}

/// Reads the metadata block byte offset and length from a Fujifilm RAF file header.
pub fn extractFujiRafMetadataLocation(header_bytes: []const u8) ?ThumbnailLocation {
    if (header_bytes.len < 100) return null;
    if (!std.mem.startsWith(u8, header_bytes, "FUJIFILM")) return null;
    const off = std.mem.readInt(u32, header_bytes[92..96], .big);
    const len = std.mem.readInt(u32, header_bytes[96..100], .big);
    if (off == 0 or len == 0) return null;
    return .{
        .file_offset = off,
        .length = len,
    };
}

/// Parses full camera sensor dimensions from the Fujifilm RAF metadata records block.
pub fn parseFujiRafDimensions(meta_bytes: []const u8) ?JpegDimensions {
    if (meta_bytes.len < 4) return null;
    const num_records = std.mem.readInt(u32, meta_bytes[0..4], .big);
    var pos: usize = 4;

    var cropped_size: ?JpegDimensions = null;
    var image_size: ?JpegDimensions = null;
    var full_size: ?JpegDimensions = null;

    var i: usize = 0;
    while (i < num_records) : (i += 1) {
        if (pos + 4 > meta_bytes.len) break;
        const tag_id = std.mem.readInt(u16, meta_bytes[pos..][0..2], .big);
        const tag_len = std.mem.readInt(u16, meta_bytes[pos + 2 ..][0..2], .big);
        pos += 4;

        if (pos + tag_len > meta_bytes.len) break;
        const tag_data = meta_bytes[pos .. pos + tag_len];
        pos += tag_len;

        if (tag_len >= 4) {
            const h = std.mem.readInt(u16, tag_data[0..2], .big);
            const w = std.mem.readInt(u16, tag_data[2..4], .big);
            if (w > 0 and h > 0) {
                const dims = JpegDimensions{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
                if (tag_id == 0x0111) {
                    cropped_size = dims;
                } else if (tag_id == 0x0121) {
                    image_size = dims;
                } else if (tag_id == 0x0100) {
                    full_size = dims;
                }
            }
        }
    }

    return cropped_size orelse (image_size orelse full_size);
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

test "extractJpegThumbnailLocation" {
    try std.testing.expectEqual(
        @as(?ThumbnailLocation, null),
        extractJpegThumbnailLocation("invalid data"),
    );

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
        // Tag 0x0201: Thumb offset = 56
        0x01, 0x02,
        0x04, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x38, 0x00,
        0x00, 0x00,
        // Tag 0x0202: Thumb len = 4
        0x02, 0x02,
        0x04, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x04, 0x00,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, // Next IFD offset = 0
        0xFF, 0xD8, 0xFF, 0xD9, // Thumb payload at offset 56 in TIFF (68 in full buffer)
    };

    const loc = extractJpegThumbnailLocation(&exif_data);
    try std.testing.expect(loc != null);
    try std.testing.expectEqual(@as(u64, 68), loc.?.file_offset);
    try std.testing.expectEqual(@as(u32, 4), loc.?.length);
    const off = @as(usize, @intCast(loc.?.file_offset));
    const len = @as(usize, @intCast(loc.?.length));
    try std.testing.expectEqualSlices(u8, &dummy_jpeg, exif_data[off .. off + len]);
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

test "TIFF container direct parsing and extractTiffRawPreviews" {
    // Mock Sony ARW / TIFF container:
    // TIFF header (8 bytes):
    // "II", sig 42, IFD0 offset = 8
    // IFD0: 3 entries:
    //  - 0x0100 (ImageWidth) = 7952 (LONG)
    //  - 0x0101 (ImageLength) = 5304 (LONG)
    //  - 0x0112 (Orientation) = 6 (SHORT, 90 deg)
    // Next IFD = 50 (IFD1)
    // IFD1 at 50: 2 entries:
    //  - 0x0201 (Thumb offset) = 1000
    //  - 0x0202 (Thumb len) = 2000000 (2MB preview)
    // Next IFD = 0
    var tiff_buf = [_]u8{0} ** 128;
    // TIFF header
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    std.mem.writeInt(u16, tiff_buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 at offset 8: 3 entries
    std.mem.writeInt(u16, tiff_buf[8..10], 3, .little);
    // Entry 0: 0x0100 ImageWidth = 7952
    std.mem.writeInt(u16, tiff_buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[12..14], 4, .little); // LONG
    std.mem.writeInt(u32, tiff_buf[14..18], 1, .little);
    std.mem.writeInt(u32, tiff_buf[18..22], 7952, .little);

    // Entry 1: 0x0101 ImageLength = 5304
    std.mem.writeInt(u16, tiff_buf[22..24], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[24..26], 4, .little); // LONG
    std.mem.writeInt(u32, tiff_buf[26..30], 1, .little);
    std.mem.writeInt(u32, tiff_buf[30..34], 5304, .little);

    // Entry 2: 0x0112 Orientation = 6 (90 deg)
    std.mem.writeInt(u16, tiff_buf[34..36], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[36..38], 3, .little); // SHORT
    std.mem.writeInt(u32, tiff_buf[38..42], 1, .little);
    std.mem.writeInt(u16, tiff_buf[42..44], 6, .little);

    // Next IFD pointer at offset 46 -> 50
    std.mem.writeInt(u32, tiff_buf[46..50], 50, .little);

    // IFD1 at offset 50: 2 entries
    std.mem.writeInt(u16, tiff_buf[50..52], 2, .little);
    // Entry 0: 0x0201 JPEG offset = 1000
    std.mem.writeInt(u16, tiff_buf[52..54], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[54..56], 4, .little);
    std.mem.writeInt(u32, tiff_buf[56..60], 1, .little);
    std.mem.writeInt(u32, tiff_buf[60..64], 1000, .little);

    // Entry 1: 0x0202 JPEG length = 2000000
    std.mem.writeInt(u16, tiff_buf[64..66], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[66..68], 4, .little);
    std.mem.writeInt(u32, tiff_buf[68..72], 1, .little);
    std.mem.writeInt(u32, tiff_buf[72..76], 2000000, .little);

    // Direct dimensions parse
    const dims = parseExifDimensions(&tiff_buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 7952.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 5304.0), dims.?.h);

    // Direct orientation parse
    const ori = parseExifOrientation(&tiff_buf);
    try std.testing.expectEqual(@as(?Orientation, .rotate_90), ori);

    // Preview extraction
    const raw_prevs = extractTiffRawPreviews(&tiff_buf);
    try std.testing.expect(raw_prevs.preview != null);
    try std.testing.expectEqual(@as(u64, 1000), raw_prevs.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 2000000), raw_prevs.preview.?.length);
}

test "Fujifilm RAF header and metadata dimension parsing" {
    var raf_header = [_]u8{0} ** 120;
    @memcpy(raf_header[0..8], "FUJIFILM");

    // Preview offset = 2048, length = 1500000
    std.mem.writeInt(u32, raf_header[84..88], 2048, .big);
    std.mem.writeInt(u32, raf_header[88..92], 1500000, .big);

    // Metadata offset = 100, length = 40
    std.mem.writeInt(u32, raf_header[92..96], 100, .big);
    std.mem.writeInt(u32, raf_header[96..100], 40, .big);

    const prev_loc = extractFujiRafPreviewLocation(&raf_header);
    try std.testing.expect(prev_loc != null);
    try std.testing.expectEqual(@as(u64, 2048), prev_loc.?.file_offset);
    try std.testing.expectEqual(@as(u32, 1500000), prev_loc.?.length);

    const meta_loc = extractFujiRafMetadataLocation(&raf_header);
    try std.testing.expect(meta_loc != null);
    try std.testing.expectEqual(@as(u64, 100), meta_loc.?.file_offset);
    try std.testing.expectEqual(@as(u32, 40), meta_loc.?.length);

    // Mock RAF metadata block:
    // num_records = 1
    // record 0: tag_id = 0x0111 (cropped), tag_len = 4, data = [height: 4160, width: 6240]
    var meta_buf = [_]u8{0} ** 32;
    std.mem.writeInt(u32, meta_buf[0..4], 1, .big);
    std.mem.writeInt(u16, meta_buf[4..6], 0x0111, .big);
    std.mem.writeInt(u16, meta_buf[6..8], 4, .big);
    std.mem.writeInt(u16, meta_buf[8..10], 4160, .big); // height
    std.mem.writeInt(u16, meta_buf[10..12], 6240, .big); // width

    const fuji_dims = parseFujiRafDimensions(&meta_buf);
    try std.testing.expect(fuji_dims != null);
    try std.testing.expectEqual(@as(f32, 6240.0), fuji_dims.?.w);
    try std.testing.expectEqual(@as(f32, 4160.0), fuji_dims.?.h);
}

test "SubIfdList capacity clamping on overflow" {
    var list = SubIfdList{};
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        list.append(100 + i);
    }
    try std.testing.expectEqual(@as(usize, 8), list.len);
    try std.testing.expectEqual(@as(usize, 8), list.slice().len);

    // 9th element is safely ignored/clamped to buffer capacity
    list.append(999);
    try std.testing.expectEqual(@as(usize, 8), list.len);
}

test "parseExifOrientation with truncated APP1 segment" {
    // Construct a JPEG header with APP1 stating length = 60000 bytes,
    // but only provide the first 50 bytes in memory (holding IFD0 with Orientation 8).
    var buf: [50]u8 = undefined;
    @memset(&buf, 0);

    // JPEG SOI
    buf[0] = 0xFF;
    buf[1] = 0xD8;

    // APP1 Marker
    buf[2] = 0xFF;
    buf[3] = 0xE1;
    // Stated length: 60,000 bytes (far exceeding buf.len)
    std.mem.writeInt(u16, buf[4..6][0..2], 60000, .big);

    // Exif identifier: "Exif\0\0"
    @memcpy(buf[6..12], "Exif\x00\x00");

    // TIFF Header: "II" (little endian), magic 42, offset 8
    buf[12] = 'I';
    buf[13] = 'I';
    std.mem.writeInt(u16, buf[14..16][0..2], 0x002A, .little);
    // IFD0 at offset 8 (relative to TIFF start at 12 -> index 20)
    std.mem.writeInt(u32, buf[16..20][0..4], 8, .little);

    // IFD0: 1 entry
    std.mem.writeInt(u16, buf[20..22][0..2], 1, .little);

    // Entry 0: tag 0x0112 (Orientation), type SHORT (3), count 1, value 8 (rotate_270)
    std.mem.writeInt(u16, buf[22..24][0..2], 0x0112, .little);
    std.mem.writeInt(u16, buf[24..26][0..2], 3, .little);
    std.mem.writeInt(u32, buf[26..30][0..4], 1, .little);
    std.mem.writeInt(u16, buf[30..32][0..2], 8, .little); // value 8
    std.mem.writeInt(u16, buf[32..34][0..2], 0, .little);

    // parseExifOrientation must successfully parse tag 0x0112 = 8 (.rotate_270)
    // even though the stated APP1 segment length is 60,000 bytes and the slice is only 50 bytes!
    const orient = parseExifOrientation(&buf);
    try std.testing.expect(orient != null);
    try std.testing.expectEqual(@as(Orientation, .rotate_270), orient.?);
}

test "DNG container with SubIFD JPEG preview strips" {
    // Mock DNG container:
    // TIFF header (8 bytes): "II", sig 42, IFD0 at offset 8
    // IFD0 at offset 8: 2 entries:
    //  - 0x00FE (NewSubfileType) = 1
    //  - 0x014A (SubIFDs) = 40 (points to SubIFD at 40)
    // Next IFD = 0
    // SubIFD at offset 40: 6 entries:
    //  - 0x0100 (ImageWidth) = 6000
    //  - 0x0101 (ImageLength) = 4000
    //  - 0x0103 (Compression) = 7 (JPEG)
    //  - 0x0106 (PhotometricInterpretation) = 6 (YCbCr)
    //  - 0x0111 (StripOffsets) = 500000
    //  - 0x0117 (StripByteCounts) = 2500000
    var buf = [_]u8{0} ** 256;
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 2 entries
    std.mem.writeInt(u16, buf[8..10], 2, .little);
    // Entry 0: 0x00FE NewSubfileType = 1
    std.mem.writeInt(u16, buf[10..12], 0x00FE, .little);
    std.mem.writeInt(u16, buf[12..14], 4, .little);
    std.mem.writeInt(u32, buf[14..18], 1, .little);
    std.mem.writeInt(u32, buf[18..22], 1, .little);
    // Entry 1: 0x014A SubIFD = 40
    std.mem.writeInt(u16, buf[22..24], 0x014A, .little);
    std.mem.writeInt(u16, buf[24..26], 4, .little);
    std.mem.writeInt(u32, buf[26..30], 1, .little);
    std.mem.writeInt(u32, buf[30..34], 40, .little);
    // Next IFD = 0
    std.mem.writeInt(u32, buf[34..38], 0, .little);

    // SubIFD at offset 40: 6 entries
    std.mem.writeInt(u16, buf[40..42], 6, .little);
    var p: usize = 42;

    // SubEntry 0: 0x0100 ImageWidth = 6000
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0100, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 .. p + 12][0..4], 6000, .little);
    p += 12;

    // SubEntry 1: 0x0101 ImageLength = 4000
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0101, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 .. p + 12][0..4], 4000, .little);
    p += 12;

    // SubEntry 2: 0x0103 Compression = 7 (JPEG)
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0103, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 3, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u16, buf[p + 8 .. p + 10][0..2], 7, .little);
    p += 12;

    // SubEntry 3: 0x0106 Photometric = 6 (YCbCr)
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0106, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 3, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u16, buf[p + 8 .. p + 10][0..2], 6, .little);
    p += 12;

    // SubEntry 4: 0x0111 StripOffsets = 500000
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0111, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 .. p + 12][0..4], 500000, .little);
    p += 12;

    // SubEntry 5: 0x0117 StripByteCounts = 2500000
    std.mem.writeInt(u16, buf[p .. p + 2][0..2], 0x0117, .little);
    std.mem.writeInt(u16, buf[p + 2 .. p + 4][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 .. p + 8][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 .. p + 12][0..4], 2500000, .little);
    p += 12;

    const raw_cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(raw_cands.preview != null);
    try std.testing.expectEqual(@as(u64, 500000), raw_cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 2500000), raw_cands.preview.?.length);
    try std.testing.expect(raw_cands.thumbnail == null);

    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 6000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.h);
}

test "Ricoh GR III DNG MakerNote thumbnail extraction (tag 0xC634)" {
    var buf = [_]u8{0} ** 512;
    // TIFF header
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 1 entry
    std.mem.writeInt(u16, buf[8..10], 1, .little);
    // Entry 0: tag 0xC634 (DNGPrivateData), type 7, val_count = 10000, val_or_off = 30
    std.mem.writeInt(u16, buf[10..12], 0xC634, .little);
    std.mem.writeInt(u16, buf[12..14], 7, .little);
    std.mem.writeInt(u32, buf[14..18], 10000, .little);
    std.mem.writeInt(u32, buf[18..22], 30, .little);
    // Next IFD = 0
    std.mem.writeInt(u32, buf[22..26], 0, .little);

    // MakerNote at offset 30
    @memcpy(buf[30..38], "RICOH\x00II");
    // p_len at offset 30 + 54 = 84: 5000 bytes
    std.mem.writeInt(u32, buf[84..88], 5000, .little);
    // p_rel_off at offset 30 + 66 = 96: 100 bytes
    std.mem.writeInt(u32, buf[96..100], 100, .little);

    const cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 130), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 5000), cands.thumbnail.?.length);
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 130), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 5000), cands.preview.?.length);
}

test "TIFF multi-IFD chained preview extraction and raw Bayer rejection" {
    // Buffer layout:
    // 0..8: TIFF header (IFD0 at 8)
    // 8..52: IFD0 (2 entries: 0x014A SubIFD at 100, 0x0201/0x0202 JPEG at 1000 len 100000, next IFD at 52 -> 150)
    // 100..186: SubIFD0 (6 entries: 0x00FE=0 (Raw), 0x0100=6000, 0x0101=4000, 0x0103=7, 0x0106=6, 0x0111/0x0117 Strip at 50000 len 30000000)
    // 190..234: IFD1 (2 entries: 0x0201/0x0202 JPEG at 2000 len 5000 (thumb), next IFD at 234 -> 240)
    // 240..278: IFD2 (2 entries: 0x0201/0x0202 JPEG at 3000 len 1000000 (full prev), next IFD -> 0)
    var buf = [_]u8{0} ** 512;
    // TIFF header
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0 at 8: 3 entries
    std.mem.writeInt(u16, buf[8..10], 3, .little);
    var p: usize = 10;
    // Entry 0: 0x014A SubIFD = 60
    std.mem.writeInt(u16, buf[p..][0..2], 0x014A, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 60, .little);
    p += 12;
    // Entry 1: 0x0201 JPEG offset = 1000
    std.mem.writeInt(u16, buf[p..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 1000, .little);
    p += 12;
    // Entry 2: 0x0202 JPEG length = 100000 (100KB preview)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 100000, .little);
    p += 12;
    // Next IFD = 150 (IFD1)
    std.mem.writeInt(u32, buf[p..][0..4], 150, .little);

    // SubIFD0 at 60: 7 entries (Sony RAW Bayer stream)
    p = 60;
    std.mem.writeInt(u16, buf[p..][0..2], 7, .little);
    p += 2;
    // Entry 0: 0x00FE NewSubfileType = 0 (Full resolution primary raw)
    std.mem.writeInt(u16, buf[p..][0..2], 0x00FE, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 0, .little);
    p += 12;
    // Entry 1: 0x0103 Compression = 7
    std.mem.writeInt(u16, buf[p..][0..2], 0x0103, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u16, buf[p + 8 ..][0..2], 7, .little);
    p += 12;
    // Entry 2: 0x0106 Photometric = 6
    std.mem.writeInt(u16, buf[p..][0..2], 0x0106, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u16, buf[p + 8 ..][0..2], 6, .little);
    p += 12;
    // Entry 3: 0x0111 StripOffsets = 50000
    std.mem.writeInt(u16, buf[p..][0..2], 0x0111, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 50000, .little);
    p += 12;
    // Entry 4: 0x0117 StripByteCounts = 30000000 (30MB raw stream)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0117, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 30000000, .little);
    p += 12;
    // Entry 5: 0x0100 ImageWidth = 8000 (raw sensor width)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 8000, .little);
    p += 12;
    // Entry 6: 0x0101 ImageLength = 6000 (raw sensor height)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 6000, .little);
    p += 12;
    // Next IFD = 0
    std.mem.writeInt(u32, buf[p..][0..4], 0, .little);

    // IFD1 at 150: 2 entries (thumbnail)
    p = 150;
    std.mem.writeInt(u16, buf[p..][0..2], 2, .little);
    p += 2;
    // Entry 0: 0x0201 JPEG offset = 2000
    std.mem.writeInt(u16, buf[p..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 2000, .little);
    p += 12;
    // Entry 1: 0x0202 JPEG length = 5000 (5KB thumbnail)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 5000, .little);
    p += 12;
    // Next IFD = 200 (IFD2)
    std.mem.writeInt(u32, buf[p..][0..4], 200, .little);

    // IFD2 at 200: 4 entries (full-size preview)
    p = 200;
    std.mem.writeInt(u16, buf[p..][0..2], 4, .little);
    p += 2;
    // Entry 0: 0x0201 JPEG offset = 3000
    std.mem.writeInt(u16, buf[p..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 3000, .little);
    p += 12;
    // Entry 1: 0x0202 JPEG length = 1000000 (1MB full preview)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 1000000, .little);
    p += 12;
    // Entry 2: 0x0100 ImageWidth = 6000 (visible photograph width)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 6000, .little);
    p += 12;
    // Entry 3: 0x0101 ImageLength = 4000 (visible photograph height)
    std.mem.writeInt(u16, buf[p..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], 4000, .little);
    p += 12;
    // Next IFD = 0
    std.mem.writeInt(u32, buf[p..][0..4], 0, .little);

    const cands = extractTiffRawPreviews(&buf);
    // Verified: Raw Bayer 30MB stream is rejected
    // Verified: IFD2 (1MB) is selected as largest preview
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 3000), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 1000000), cands.preview.?.length);

    // Verified: IFD1 (5KB) is selected as smallest thumbnail
    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 2000), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 5000), cands.thumbnail.?.length);

    // Verified: IFD0 (100KB) is selected as medium preview
    try std.testing.expect(cands.medium != null);
    try std.testing.expectEqual(@as(u64, 1000), cands.medium.?.file_offset);
    try std.testing.expectEqual(@as(u32, 100000), cands.medium.?.length);

    // Verified: parseExifDimensions rejects raw Bayer 8000x6000 SubIFD
    // and correctly returns IFD2 visible photograph dimensions 6000x4000.
    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 6000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.h);
}

test "extractTiffRawPreviews - real DSC00941.ARW" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, "DSC00941.ARW", .{}) catch return;
    defer file.close(io);

    var header_buf: [256 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(io, &slices, 0) catch return;
    if (n < 8) return;

    const cands = extractTiffRawPreviews(header_buf[0..n]);
    // IFD2 full preview: 6240x4160 JPEG at 303104 len 1067474
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 303104), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 1067474), cands.preview.?.length);

    // IFD0 medium preview: 1616x1080 JPEG at 196770 len 103242
    try std.testing.expect(cands.medium != null);
    try std.testing.expectEqual(@as(u64, 196770), cands.medium.?.file_offset);
    try std.testing.expectEqual(@as(u32, 103242), cands.medium.?.length);

    // IFD1 thumbnail: 160x120 JPEG at 44032 len 5521
    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 44032), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 5521), cands.thumbnail.?.length);

    const dims = parseExifDimensions(header_buf[0..n]);
    try std.testing.expect(dims != null);
    // Verifies visible photograph dimensions (6240 x 4160) are returned,
    // rejecting the SubIFD raw Bayer sensor array (6656 x 4608).
    try std.testing.expectEqual(@as(f32, 6240.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4160.0), dims.?.h);

    // Verifies thumbnail letterbox padding detection eliminates black borders:
    // With full_w = 6240 and full_h = 4160 (AR = 1.500000), 160x120 thumbnail snaps to 8px DCT block.
    const crop = state_pkg.computeThumbnailUvCrop(dims.?.w, dims.?.h, 160.0, 120.0, true);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 120.0), crop.v_min, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 8.0 / 120.0), crop.v_max, 0.0001);
}

test "extractTiffRawPreviews - real test.dng streaming tail IFD0" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, "test.dng", .{}) catch return;
    defer file.close(io);

    const stat = try file.stat(io);
    const file_size: u64 = stat.size;

    var header_buf: [256 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const header_n = file.readPositional(io, &slices, 0) catch return;
    if (header_n < 8) return;
    const header_slice = header_buf[0..header_n];

    const ifd0_off = probeTiffIfd0Offset(header_slice) orelse return;
    try std.testing.expect(ifd0_off >= header_n); // Confirms tail IFD0 in test.dng

    var tail_buf: [64 * 1024]u8 = undefined;
    const tail_target: usize = @intCast(@min(file_size - ifd0_off, tail_buf.len));
    var t_slices = [_][]u8{tail_buf[0..tail_target]};
    const tn = try file.readPositional(io, &t_slices, ifd0_off);
    try std.testing.expect(tn > 0);

    const source = TiffSource.initWithTail(header_slice, ifd0_off, tail_buf[0..tn]);

    // SubIFD[1] full preview: 6000x4000 JPEG at offset 27316832 len 2943618
    const cands = extractTiffRawPreviewsFromSource(source);
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 27316832), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 2943618), cands.preview.?.length);

    // DNGPrivateData MakerNote thumbnail: 720x480 JPEG at offset 97056 len 54247
    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 97056), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 54247), cands.thumbnail.?.length);

    // Dimensions: SubIFD[1] 6000x4000, rejecting raw CFA Bayer SubIFD[0] 6112x4064
    const dims = parseExifDimensionsFromSource(source);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 6000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.h);

    // Orientation: tag 0x0112 in IFD0 at tail
    const orientation = parseExifOrientationFromSource(source);
    try std.testing.expect(orientation != null);
    try std.testing.expectEqual(Orientation.normal, orientation.?);
}

test "probeTiffIfd0Offset - validation and bounds checks" {
    // 1. Truncated header (< 8 bytes)
    try std.testing.expectEqual(@as(?u32, null), probeTiffIfd0Offset(""));
    try std.testing.expectEqual(@as(?u32, null), probeTiffIfd0Offset("II\x2A\x00"));
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("MM\x00\x2A\x00\x00\x00"),
    );

    // 2. Invalid magic (neither II nor MM)
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("XX\x2A\x00\x08\x00\x00\x00"),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("\xFF\xD8\xFF\xE1\x00\x10\x45\x78"),
    );

    // 3. Invalid TIFF version (e.g. BigTIFF 43 instead of 42)
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("II\x2B\x00\x08\x00\x00\x00"),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("MM\x00\x2B\x00\x00\x00\x08"),
    );

    // 4. Invalid IFD0 offset (< 8 or odd/unaligned)
    // off = 4 < 8
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("II\x2A\x00\x04\x00\x00\x00"),
    );
    // off = 9 (odd)
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("II\x2A\x00\x09\x00\x00\x00"),
    );

    // 5. Valid Little-Endian (II) and Big-Endian (MM)
    try std.testing.expectEqual(
        @as(?u32, 8),
        probeTiffIfd0Offset("II\x2A\x00\x08\x00\x00\x00"),
    );
    try std.testing.expectEqual(
        @as(?u32, 8),
        probeTiffIfd0Offset("MM\x00\x2A\x00\x00\x00\x08"),
    );
    try std.testing.expectEqual(
        @as(?u32, 27317856),
        probeTiffIfd0Offset("II\x2A\x00\x60\xD6\xA0\x01"),
    );
}

test "TiffSource.getSlice - bounds, split reads, and overflow safety" {
    const hdr = "0123456789ABCDEF"; // 16 bytes, offset 0..16
    const tail = "UVWXYZ"; // 6 bytes, tail_offset = 100 (100..106)
    const src = TiffSource.initWithTail(hdr, 100, tail);

    // In-bounds header reads
    try std.testing.expectEqualStrings("0123", src.getSlice(0, 4).?);
    try std.testing.expectEqualStrings("CDEF", src.getSlice(12, 4).?);

    // Split read across header boundary: starts in header, ends beyond header
    try std.testing.expect(src.getSlice(12, 8) == null);

    // Read in the gap between header and tail
    try std.testing.expect(src.getSlice(16, 4) == null);
    try std.testing.expect(src.getSlice(50, 4) == null);
    try std.testing.expect(src.getSlice(98, 4) == null);

    // In-bounds tail reads
    try std.testing.expectEqualStrings("UV", src.getSlice(100, 2).?);
    try std.testing.expectEqualStrings("YZ", src.getSlice(104, 2).?);

    // Read extending past tail end
    try std.testing.expect(src.getSlice(104, 4) == null);
    try std.testing.expect(src.getSlice(106, 1) == null);

    // Integer overflow protection on offset + length
    try std.testing.expect(src.getSlice(std.math.maxInt(usize), 1) == null);
    try std.testing.expect(src.getSlice(std.math.maxInt(usize) - 2, 10) == null);
}

test "synthetic streaming tail IFD0 - dimensions, orientation, and preview extraction" {
    // Construct 8-byte TIFF container header pointing to tail IFD0 at offset 1000
    var hdr: [8]u8 = undefined;
    hdr[0] = 'I';
    hdr[1] = 'I';
    std.mem.writeInt(u16, hdr[2..4], 0x002A, .little);
    std.mem.writeInt(u32, hdr[4..8], 1000, .little);

    // Construct 128-byte tail buffer starting at offset 1000
    var tail: [128]u8 = undefined;
    @memset(&tail, 0);

    // IFD0 at rel = 0 (file offset 1000): 5 entries
    std.mem.writeInt(u16, tail[0..2], 5, .little);

    // Entry 0: tag 0x0100 (ImageWidth), SHORT (3), count 1, val 4000
    std.mem.writeInt(u16, tail[2..4], 0x0100, .little);
    std.mem.writeInt(u16, tail[4..6], 3, .little);
    std.mem.writeInt(u32, tail[6..10], 1, .little);
    std.mem.writeInt(u16, tail[10..12], 4000, .little);

    // Entry 1: tag 0x0101 (ImageLength), SHORT (3), count 1, val 3000
    std.mem.writeInt(u16, tail[14..16], 0x0101, .little);
    std.mem.writeInt(u16, tail[16..18], 3, .little);
    std.mem.writeInt(u32, tail[18..22], 1, .little);
    std.mem.writeInt(u16, tail[22..24], 3000, .little);

    // Entry 2: tag 0x0112 (Orientation), SHORT (3), count 1, val 6 (.rotate_90)
    std.mem.writeInt(u16, tail[26..28], 0x0112, .little);
    std.mem.writeInt(u16, tail[28..30], 3, .little);
    std.mem.writeInt(u32, tail[30..34], 1, .little);
    std.mem.writeInt(u16, tail[34..36], 6, .little);

    // Entry 3: tag 0x0201 (JpegIFOffset), LONG (4), count 1, val 50000
    std.mem.writeInt(u16, tail[38..40], 0x0201, .little);
    std.mem.writeInt(u16, tail[40..42], 4, .little);
    std.mem.writeInt(u32, tail[42..46], 1, .little);
    std.mem.writeInt(u32, tail[46..50], 50000, .little);

    // Entry 4: tag 0x0202 (JpegIFByteCount), LONG (4), count 1, val 12000
    std.mem.writeInt(u16, tail[50..52], 0x0202, .little);
    std.mem.writeInt(u16, tail[52..54], 4, .little);
    std.mem.writeInt(u32, tail[54..58], 1, .little);
    std.mem.writeInt(u32, tail[58..62], 12000, .little);

    // Next IFD pointer: 0 (end of chain)
    std.mem.writeInt(u32, tail[62..66], 0, .little);

    const ifd0_off = probeTiffIfd0Offset(&hdr).?;
    try std.testing.expectEqual(@as(u32, 1000), ifd0_off);

    const source = TiffSource.initWithTail(&hdr, ifd0_off, &tail);

    // Test Orientation
    const orient = parseExifOrientationFromSource(source);
    try std.testing.expect(orient != null);
    try std.testing.expectEqual(Orientation.rotate_90, orient.?);

    // Test Dimensions
    const dims = parseExifDimensionsFromSource(source);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 3000.0), dims.?.h);

    // Test Preview Candidates
    const cands = extractTiffRawPreviewsFromSource(source);
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 50000), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 12000), cands.preview.?.length);
}

test "synthetic circular IFD chain in tail terminates cleanly" {
    var hdr: [8]u8 = undefined;
    hdr[0] = 'I';
    hdr[1] = 'I';
    std.mem.writeInt(u16, hdr[2..4], 0x002A, .little);
    std.mem.writeInt(u32, hdr[4..8], 1000, .little);

    // Tail buffer with 2 IFDs: IFD0 at 1000 points to IFD1 at 1030; IFD1 points back to 1000!
    var tail: [128]u8 = undefined;
    @memset(&tail, 0);

    // IFD0 at offset 1000 (rel 0): 1 entry, next_ifd = 1030
    std.mem.writeInt(u16, tail[0..2], 1, .little);
    std.mem.writeInt(u16, tail[2..4], 0x0100, .little); // ImageWidth
    std.mem.writeInt(u16, tail[4..6], 3, .little);
    std.mem.writeInt(u32, tail[6..10], 1, .little);
    std.mem.writeInt(u16, tail[10..12], 1920, .little);
    std.mem.writeInt(u32, tail[14..18], 1030, .little); // Points to IFD1

    // IFD1 at offset 1030 (rel 30): 1 entry, next_ifd = 1000 (CYCLE!)
    std.mem.writeInt(u16, tail[30..32], 1, .little);
    std.mem.writeInt(u16, tail[32..34], 0x0101, .little); // ImageLength
    std.mem.writeInt(u16, tail[34..36], 3, .little);
    std.mem.writeInt(u32, tail[36..40], 1, .little);
    std.mem.writeInt(u16, tail[40..42], 1080, .little);
    std.mem.writeInt(u32, tail[44..48], 1000, .little); // CYCLE back to 1000!

    const source = TiffSource.initWithTail(&hdr, 1000, &tail);

    // Must terminate cycle without infinite looping or stack overflow
    const dims = parseExifDimensionsFromSource(source);
    _ = dims;
    const cands = extractTiffRawPreviewsFromSource(source);
    _ = cands;
}

test "isLosslessJpeg - marker scanning" {
    // 1. Baseline JPEG (SOI + DHT + SOF0)
    const baseline = [_]u8{
        0xFF, 0xD8, 0xFF, 0xC4, 0x00, 0x04, 0x01, 0x02,
        0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x64, 0x00,
        0x64, 0x03,
    };
    try std.testing.expect(!isLosslessJpeg(&baseline));

    // 2. Lossless JPEG (SOI + DHT + SOF3)
    const lossless = [_]u8{
        0xFF, 0xD8, 0xFF, 0xC4, 0x00, 0x04, 0x01, 0x02,
        0xFF, 0xC3, 0x00, 0x0B, 0x10, 0x00, 0x64, 0x00,
        0x64, 0x01,
    };
    try std.testing.expect(isLosslessJpeg(&lossless));

    // 3. Immediate SOF3 (SOI + SOF3)
    const immediate_sof3 = [_]u8{
        0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x10, 0x00, 0x64, 0x00, 0x64, 0x01,
    };
    try std.testing.expect(isLosslessJpeg(&immediate_sof3));

    // 4. Truncated / non-JPEG
    try std.testing.expect(!isLosslessJpeg(""));
    try std.testing.expect(!isLosslessJpeg("\xFF\xD8"));
    try std.testing.expect(!isLosslessJpeg("\x0E\x20\x14\x0E"));

    // 5. Short 4-byte slice with SOF3
    try std.testing.expect(isLosslessJpeg("\xFF\xD8\xFF\xC3"));

    // 6. Fill byte padding before SOF3
    const fill_padding = [_]u8{
        0xFF, 0xD8, 0xFF, 0xFF, 0xFF, 0xC3, 0x00, 0x0B,
        0x10, 0x00, 0x64, 0x00, 0x64, 0x01,
    };
    try std.testing.expect(isLosslessJpeg(&fill_padding));

    // 7. Restart marker (RST0 / 0xD0) followed by SOF3
    const rst_marker = [_]u8{
        0xFF, 0xD8, 0xFF, 0xD0, 0xFF, 0xC3, 0x00, 0x0B,
        0x10, 0x00, 0x64, 0x00, 0x64, 0x01,
    };
    try std.testing.expect(isLosslessJpeg(&rst_marker));

    // 8. Byte stuffing (0xFF 0x00) should abort scan and return false
    const byte_stuffed = [_]u8{
        0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xC3, 0x00, 0x0B,
        0x10, 0x00, 0x64, 0x00, 0x64, 0x01,
    };
    try std.testing.expect(!isLosslessJpeg(&byte_stuffed));
}

test "extractTiffRawPreviews - synthetic Canon CR2 multi-IFD container" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);

    // TIFF Header: little-endian, IFD0 offset 16
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 16, .little);

    // Canon CR2 signature at bytes 8..12 ("CR\x02\x00")
    buf[8] = 'C';
    buf[9] = 'R';
    buf[10] = 0x02;
    buf[11] = 0x00;

    // IFD0 at offset 16: 6 entries, next_ifd = 94
    std.mem.writeInt(u16, buf[16..18], 6, .little);
    // Entry 0: ImageWidth = 2496
    std.mem.writeInt(u16, buf[18..20], 0x0100, .little);
    std.mem.writeInt(u16, buf[20..22], 3, .little);
    std.mem.writeInt(u32, buf[22..26], 1, .little);
    std.mem.writeInt(u16, buf[26..28], 2496, .little);
    // Entry 1: ImageLength = 1664
    std.mem.writeInt(u16, buf[30..32], 0x0101, .little);
    std.mem.writeInt(u16, buf[32..34], 3, .little);
    std.mem.writeInt(u32, buf[34..38], 1, .little);
    std.mem.writeInt(u16, buf[38..40], 1664, .little);
    // Entry 2: Compression = 6 (jpeg_old)
    std.mem.writeInt(u16, buf[42..44], 0x0103, .little);
    std.mem.writeInt(u16, buf[44..46], 3, .little);
    std.mem.writeInt(u32, buf[46..50], 1, .little);
    std.mem.writeInt(u16, buf[50..52], 6, .little);
    // Entry 3: StripOffsets = 300
    std.mem.writeInt(u16, buf[54..56], 0x0111, .little);
    std.mem.writeInt(u16, buf[56..58], 4, .little);
    std.mem.writeInt(u32, buf[58..62], 1, .little);
    std.mem.writeInt(u32, buf[62..66], 300, .little);
    // Entry 4: StripByteCounts = 50
    std.mem.writeInt(u16, buf[66..68], 0x0117, .little);
    std.mem.writeInt(u16, buf[68..70], 4, .little);
    std.mem.writeInt(u32, buf[70..74], 1, .little);
    std.mem.writeInt(u32, buf[74..78], 50, .little);
    // Entry 5: ExifIFD pointer = 260
    std.mem.writeInt(u16, buf[78..80], 0x8769, .little);
    std.mem.writeInt(u16, buf[80..82], 4, .little);
    std.mem.writeInt(u32, buf[82..86], 1, .little);
    std.mem.writeInt(u32, buf[86..90], 260, .little);
    // Next IFD = 94 (IFD1)
    std.mem.writeInt(u32, buf[90..94], 94, .little);

    // IFD1 at offset 94: 4 entries, next_ifd = 148
    std.mem.writeInt(u16, buf[94..96], 4, .little);
    // Entry 0: ImageWidth = 160
    std.mem.writeInt(u16, buf[96..98], 0x0100, .little);
    std.mem.writeInt(u16, buf[98..100], 3, .little);
    std.mem.writeInt(u32, buf[100..104], 1, .little);
    std.mem.writeInt(u16, buf[104..106], 160, .little);
    // Entry 1: ImageLength = 120
    std.mem.writeInt(u16, buf[108..110], 0x0101, .little);
    std.mem.writeInt(u16, buf[110..112], 3, .little);
    std.mem.writeInt(u32, buf[112..116], 1, .little);
    std.mem.writeInt(u16, buf[116..118], 120, .little);
    // Entry 2: JpegInterchangeFormat = 360
    std.mem.writeInt(u16, buf[120..122], 0x0201, .little);
    std.mem.writeInt(u16, buf[122..124], 4, .little);
    std.mem.writeInt(u32, buf[124..128], 1, .little);
    std.mem.writeInt(u32, buf[128..132], 360, .little);
    // Entry 3: JpegInterchangeFormatLength = 40
    std.mem.writeInt(u16, buf[132..134], 0x0202, .little);
    std.mem.writeInt(u16, buf[134..136], 4, .little);
    std.mem.writeInt(u32, buf[136..140], 1, .little);
    std.mem.writeInt(u32, buf[140..144], 40, .little);
    // Next IFD = 148 (IFD2)
    std.mem.writeInt(u32, buf[144..148], 148, .little);

    // IFD2 at offset 148: 4 entries, next_ifd = 202
    std.mem.writeInt(u16, buf[148..150], 4, .little);
    // Entry 0: ImageWidth = 384
    std.mem.writeInt(u16, buf[150..152], 0x0100, .little);
    std.mem.writeInt(u16, buf[152..154], 3, .little);
    std.mem.writeInt(u32, buf[154..158], 1, .little);
    std.mem.writeInt(u16, buf[158..160], 384, .little);
    // Entry 1: ImageLength = 256
    std.mem.writeInt(u16, buf[162..164], 0x0101, .little);
    std.mem.writeInt(u16, buf[164..166], 3, .little);
    std.mem.writeInt(u32, buf[166..170], 1, .little);
    std.mem.writeInt(u16, buf[170..172], 256, .little);
    // Entry 2: StripOffsets = 410
    std.mem.writeInt(u16, buf[174..176], 0x0111, .little);
    std.mem.writeInt(u16, buf[176..178], 4, .little);
    std.mem.writeInt(u32, buf[178..182], 1, .little);
    std.mem.writeInt(u32, buf[182..186], 410, .little);
    // Entry 3: StripByteCounts = 30
    std.mem.writeInt(u16, buf[186..188], 0x0117, .little);
    std.mem.writeInt(u16, buf[188..190], 4, .little);
    std.mem.writeInt(u32, buf[190..194], 1, .little);
    std.mem.writeInt(u32, buf[194..198], 30, .little);
    // Next IFD = 202 (IFD3)
    std.mem.writeInt(u32, buf[198..202], 202, .little);

    // IFD3 at offset 202: 4 entries, next_ifd = 0
    std.mem.writeInt(u16, buf[202..204], 4, .little);
    // Entry 0: ImageWidth = 4476
    std.mem.writeInt(u16, buf[204..206], 0x0100, .little);
    std.mem.writeInt(u16, buf[206..208], 3, .little);
    std.mem.writeInt(u32, buf[208..212], 1, .little);
    std.mem.writeInt(u16, buf[212..214], 4476, .little);
    // Entry 1: ImageLength = 2954
    std.mem.writeInt(u16, buf[216..218], 0x0101, .little);
    std.mem.writeInt(u16, buf[218..220], 3, .little);
    std.mem.writeInt(u32, buf[220..224], 1, .little);
    std.mem.writeInt(u16, buf[224..226], 2954, .little);
    // Entry 2: StripOffsets = 450
    std.mem.writeInt(u16, buf[228..230], 0x0111, .little);
    std.mem.writeInt(u16, buf[230..232], 4, .little);
    std.mem.writeInt(u32, buf[232..236], 1, .little);
    std.mem.writeInt(u32, buf[236..240], 450, .little);
    // Entry 3: StripByteCounts = 40
    std.mem.writeInt(u16, buf[240..242], 0x0117, .little);
    std.mem.writeInt(u16, buf[242..244], 4, .little);
    std.mem.writeInt(u32, buf[244..248], 1, .little);
    std.mem.writeInt(u32, buf[248..252], 40, .little);
    // Next IFD = 0
    std.mem.writeInt(u32, buf[252..256], 0, .little);

    // ExifIFD at offset 260: 2 entries, next_ifd = 0
    std.mem.writeInt(u16, buf[260..262], 2, .little);
    // Entry 0: PixelXDimension = 4368
    std.mem.writeInt(u16, buf[262..264], 0xA002, .little);
    std.mem.writeInt(u16, buf[264..266], 4, .little);
    std.mem.writeInt(u32, buf[266..270], 1, .little);
    std.mem.writeInt(u32, buf[270..274], 4368, .little);
    // Entry 1: PixelYDimension = 2912
    std.mem.writeInt(u16, buf[274..276], 0xA003, .little);
    std.mem.writeInt(u16, buf[276..278], 4, .little);
    std.mem.writeInt(u32, buf[278..282], 1, .little);
    std.mem.writeInt(u32, buf[282..286], 2912, .little);
    std.mem.writeInt(u32, buf[286..290], 0, .little);

    // Payloads:
    // IFD0 preview: baseline JPEG at offset 300
    buf[300] = 0xFF;
    buf[301] = 0xD8;
    buf[302] = 0xFF;
    buf[303] = 0xC0;

    // IFD1 thumbnail: JPEG at offset 360
    buf[360] = 0xFF;
    buf[361] = 0xD8;

    // IFD2: uncompressed raw RGB at offset 410 (no SOI)
    buf[410] = 0x0E;
    buf[411] = 0x20;
    buf[412] = 0x14;
    buf[413] = 0x0E;

    // IFD3: Lossless JPEG Bayer sensor stream at offset 450 (SOF3)
    buf[450] = 0xFF;
    buf[451] = 0xD8;
    buf[452] = 0xFF;
    buf[453] = 0xC3;

    // 1. Candidate extraction must pick IFD0 and IFD1, rejecting IFD2 and IFD3
    const cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 300), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 50), cands.preview.?.length);

    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 360), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 40), cands.thumbnail.?.length);

    // 2. Exif dimensions must extract 4368x2912 from ExifIFD (ignoring IFD2/IFD3)
    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 4368.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 2912.0), dims.?.h);
}

test "extractTiffRawPreviews - real 20240523-Phoebe is mad-0076.CR2" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        "20240523-Phoebe is mad-0076.CR2",
        .{},
    ) catch return;
    defer file.close(io);

    var header_buf: [256 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(io, &slices, 0) catch return;
    if (n < 8) return;

    const cands = extractTiffRawPreviews(header_buf[0..n]);
    // IFD0 full preview: 2496x1664 baseline JPEG at offset 87197 len 1426156
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 87197), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 1426156), cands.preview.?.length);

    // IFD1 thumbnail: 160x120 JPEG at offset 76348 len 10849
    try std.testing.expect(cands.thumbnail != null);
    try std.testing.expectEqual(@as(u64, 76348), cands.thumbnail.?.file_offset);
    try std.testing.expectEqual(@as(u32, 10849), cands.thumbnail.?.length);

    // Dims from ExifIFD (PixelXDimension / PixelYDimension)
    const dims = parseExifDimensions(header_buf[0..n]);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 4368.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 2912.0), dims.?.h);
}

test "extractTiffRawPreviews - synthetic JPEG strip with null photometric accepted" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);

    // TIFF header (little-endian, IFD0 at 8)
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 4 entries
    std.mem.writeInt(u16, buf[8..10], 4, .little);
    // Entry 0: ImageWidth = 640
    std.mem.writeInt(u16, buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, buf[12..14], 3, .little);
    std.mem.writeInt(u32, buf[14..18], 1, .little);
    std.mem.writeInt(u16, buf[18..20], 640, .little);
    // Entry 1: Compression = 6 (jpeg_old)
    std.mem.writeInt(u16, buf[22..24], 0x0103, .little);
    std.mem.writeInt(u16, buf[24..26], 3, .little);
    std.mem.writeInt(u32, buf[26..30], 1, .little);
    std.mem.writeInt(u16, buf[30..32], 6, .little);
    // Entry 2: StripOffsets = 100
    std.mem.writeInt(u16, buf[34..36], 0x0111, .little);
    std.mem.writeInt(u16, buf[36..38], 4, .little);
    std.mem.writeInt(u32, buf[38..42], 1, .little);
    std.mem.writeInt(u32, buf[42..46], 100, .little);
    // Entry 3: StripByteCounts = 50
    std.mem.writeInt(u16, buf[46..48], 0x0117, .little);
    std.mem.writeInt(u16, buf[48..50], 4, .little);
    std.mem.writeInt(u32, buf[50..54], 1, .little);
    std.mem.writeInt(u32, buf[54..58], 50, .little);
    // Next IFD = 0
    std.mem.writeInt(u32, buf[58..62], 0, .little);

    // Valid SOI at offset 100
    buf[100] = 0xFF;
    buf[101] = 0xD8;
    buf[102] = 0xFF;
    buf[103] = 0xC0;

    const cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(cands.preview != null);
    try std.testing.expectEqual(@as(u64, 100), cands.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 50), cands.preview.?.length);
}

test "extractTiffRawPreviews - synthetic uncompressed RGB strip rejected" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);

    // TIFF header
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 4 entries, compression 6, but payload bytes are not SOI
    std.mem.writeInt(u16, buf[8..10], 4, .little);
    std.mem.writeInt(u16, buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, buf[12..14], 3, .little);
    std.mem.writeInt(u32, buf[14..18], 1, .little);
    std.mem.writeInt(u16, buf[18..20], 384, .little);

    std.mem.writeInt(u16, buf[22..24], 0x0103, .little);
    std.mem.writeInt(u16, buf[24..26], 3, .little);
    std.mem.writeInt(u32, buf[26..30], 1, .little);
    std.mem.writeInt(u16, buf[30..32], 6, .little);

    std.mem.writeInt(u16, buf[34..36], 0x0111, .little);
    std.mem.writeInt(u16, buf[36..38], 4, .little);
    std.mem.writeInt(u32, buf[38..42], 1, .little);
    std.mem.writeInt(u32, buf[42..46], 100, .little);

    std.mem.writeInt(u16, buf[46..48], 0x0117, .little);
    std.mem.writeInt(u16, buf[48..50], 4, .little);
    std.mem.writeInt(u32, buf[50..54], 1, .little);
    std.mem.writeInt(u32, buf[54..58], 50, .little);
    std.mem.writeInt(u32, buf[58..62], 0, .little);

    // Non-JPEG bytes at offset 100 (raw RGB: 0x0E, 0x20...)
    buf[100] = 0x0E;
    buf[101] = 0x20;
    buf[102] = 0x14;
    buf[103] = 0x0E;

    const cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(cands.preview == null);
}

test "extractTiffRawPreviews - synthetic Lossless JPEG SOF3 strip rejected" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);

    // TIFF header
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 4 entries, compression 6, payload has DHT then SOF3
    std.mem.writeInt(u16, buf[8..10], 4, .little);
    std.mem.writeInt(u16, buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, buf[12..14], 3, .little);
    std.mem.writeInt(u32, buf[14..18], 1, .little);
    std.mem.writeInt(u16, buf[18..20], 384, .little);

    std.mem.writeInt(u16, buf[22..24], 0x0103, .little);
    std.mem.writeInt(u16, buf[24..26], 3, .little);
    std.mem.writeInt(u32, buf[26..30], 1, .little);
    std.mem.writeInt(u16, buf[30..32], 6, .little);

    std.mem.writeInt(u16, buf[34..36], 0x0111, .little);
    std.mem.writeInt(u16, buf[36..38], 4, .little);
    std.mem.writeInt(u32, buf[38..42], 1, .little);
    std.mem.writeInt(u32, buf[42..46], 100, .little);

    std.mem.writeInt(u16, buf[46..48], 0x0117, .little);
    std.mem.writeInt(u16, buf[48..50], 4, .little);
    std.mem.writeInt(u32, buf[50..54], 1, .little);
    std.mem.writeInt(u32, buf[54..58], 50, .little);
    std.mem.writeInt(u32, buf[58..62], 0, .little);

    // SOI + DHT (length 4) + SOF3 (lossless)
    buf[100] = 0xFF;
    buf[101] = 0xD8;
    buf[102] = 0xFF;
    buf[103] = 0xC4;
    buf[104] = 0x00;
    buf[105] = 0x04;
    buf[106] = 0x01;
    buf[107] = 0x02;
    buf[108] = 0xFF;
    buf[109] = 0xC3;

    const cands = extractTiffRawPreviews(&buf);
    try std.testing.expect(cands.preview == null);
}
