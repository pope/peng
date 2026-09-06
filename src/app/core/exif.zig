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

fn findTiffPayload(data: []const u8) ?TiffHeader {
    // 1. Direct TIFF container (Sony ARW, DNG, CR2, NEF, ORF, RW2, PEF, etc.)
    if (data.len >= 8) {
        if (std.mem.eql(u8, data[0..2], "II") or std.mem.eql(u8, data[0..2], "MM")) {
            const is_le = (data[0] == 'I');
            const sig = if (is_le) std.mem.readInt(u16, data[2..4][0..2], .little) else std.mem.readInt(u16, data[2..4][0..2], .big);
            if (sig == 0x002A) {
                const ifd0_off = if (is_le) std.mem.readInt(u32, data[4..8][0..4], .little) else std.mem.readInt(u32, data[4..8][0..4], .big);
                const off: usize = ifd0_off;
                if (off + 2 <= data.len) {
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
                    const is_le = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else continue;

                    const sig = if (is_le) std.mem.readInt(u16, tiff[2..4][0..2], .little) else std.mem.readInt(u16, tiff[2..4][0..2], .big);
                    if (sig == 0x002A) {
                        const ifd0_off = if (is_le) std.mem.readInt(u32, tiff[4..8][0..4], .little) else std.mem.readInt(u32, tiff[4..8][0..4], .big);
                        const off: usize = ifd0_off;
                        if (off + 2 <= tiff.len) {
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

    pub fn append(self: *SubIfdList, item: u32) error{TooManySubIfds}!void {
        if (self.len >= self.items.len) {
            return error.TooManySubIfds;
        }
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *const SubIfdList) []const u32 {
        return self.items[0..self.len];
    }
};

/// Parses image pixel dimensions from EXIF TIFF metadata tags (IFD0, ExifIFD, or SubIFD).
pub fn parseExifDimensions(data: []const u8) ?JpegDimensions {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    var best_w: ?u32 = null;
    var best_h: ?u32 = null;
    var best_area: u64 = 0;
    var exif_sub_ifd_off: ?u32 = null;
    var sub_ifd_list: SubIfdList = .{};

    const parseIfd = struct {
        fn run(
            t: []const u8,
            off: usize,
            le: bool,
            b_w: *?u32,
            b_h: *?u32,
            b_area: *u64,
            sub_out: ?*?u32,
            sub_ifds: ?*SubIfdList,
        ) error{TooManySubIfds}!void {
            if (off >= t.len or off + 2 > t.len) return;
            const num = if (le) std.mem.readInt(u16, t[off..][0..2], .little) else std.mem.readInt(u16, t[off..][0..2], .big);
            var entry_off = off + 2;
            var i: usize = 0;
            var cur_w: ?u32 = null;
            var cur_h: ?u32 = null;

            while (i < num) : (i += 1) {
                if (entry_off + 12 > t.len) break;
                const entry = t[entry_off .. entry_off + 12];
                entry_off += 12;

                const tag = if (le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                const type_id = if (le) std.mem.readInt(u16, entry[2..4][0..2], .little) else std.mem.readInt(u16, entry[2..4][0..2], .big);
                const count = if (le) std.mem.readInt(u32, entry[4..8][0..4], .little) else std.mem.readInt(u32, entry[4..8][0..4], .big);

                var val: u32 = 0;
                if (type_id == 3) {
                    val = if (le) std.mem.readInt(u16, entry[8..10][0..2], .little) else std.mem.readInt(u16, entry[8..10][0..2], .big);
                } else if (type_id == 4) {
                    val = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                }

                if (tag == 0x0100 or tag == 0xA002) {
                    cur_w = val;
                } else if (tag == 0x0101 or tag == 0xA003) {
                    cur_h = val;
                } else if (tag == 0x8769 and sub_out != null) {
                    sub_out.?.* = val;
                } else if (tag == 0x014A and sub_ifds != null) {
                    if (count == 1) {
                        if (val > 0) try sub_ifds.?.append(val);
                    } else if (count > 1 and (type_id == 4 or type_id == 13)) {
                        if (count > 8) return error.TooManySubIfds;
                        if (val < t.len) {
                            var s_idx: usize = 0;
                            while (s_idx < count) : (s_idx += 1) {
                                const read_pos = @as(usize, val) + s_idx * 4;
                                if (read_pos + 4 <= t.len) {
                                    const s_off = if (le) std.mem.readInt(u32, t[read_pos .. read_pos + 4][0..4], .little) else std.mem.readInt(u32, t[read_pos .. read_pos + 4][0..4], .big);
                                    if (s_off > 0) try sub_ifds.?.append(s_off);
                                }
                            }
                        }
                    }
                }
            }

            if (cur_w != null and cur_h != null) {
                const area = @as(u64, cur_w.?) * @as(u64, cur_h.?);
                if (area > b_area.*) {
                    b_area.* = area;
                    b_w.* = cur_w;
                    b_h.* = cur_h;
                }
            }
        }
    }.run;

    parseIfd(tiff, ifd0_off, is_le, &best_w, &best_h, &best_area, &exif_sub_ifd_off, &sub_ifd_list) catch |err| {
        std.log.err("parseExifDimensions: failed to parse IFD0: {}", .{err});
        return null;
    };

    if (exif_sub_ifd_off) |sub_off| {
        parseIfd(tiff, sub_off, is_le, &best_w, &best_h, &best_area, null, null) catch |err| {
            std.log.warn("parseExifDimensions: failed to parse ExifIFD at offset {d}: {}", .{ sub_off, err });
        };
    }

    for (sub_ifd_list.slice()) |s_off| {
        parseIfd(tiff, s_off, is_le, &best_w, &best_h, &best_area, null, null) catch |err| {
            std.log.warn("parseExifDimensions: failed to parse SubIFD at offset {d}: {}", .{ s_off, err });
        };
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

/// Extracts the TIFF orientation tag (0x0112) from an EXIF payload.
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

/// Reads the EXIF orientation tag by reading the header of a JPEG file on disk.
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

/// Locates the byte offset and length of an embedded JPEG thumbnail in IFD1 without allocating memory.
pub fn extractJpegThumbnailLocation(data: []const u8) ?ThumbnailLocation {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    const ifd1_ptr_off = @as(usize, ifd0_off) + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 > tiff.len) return null;

    const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
    const ifd1_usize: usize = ifd1_off;
    if (ifd1_usize == 0 or ifd1_usize + 2 > tiff.len) return null;

    const num_ifd1_entries = if (is_le) std.mem.readInt(u16, tiff[ifd1_usize..][0..2], .little) else std.mem.readInt(u16, tiff[ifd1_usize..][0..2], .big);
    var entry_off = ifd1_usize + 2;

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

/// Returns a slice containing the embedded JPEG thumbnail payload if present in the EXIF data.
pub fn extractJpegThumbnail(data: []const u8) ?[]const u8 {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    const ifd1_ptr_off = @as(usize, ifd0_off) + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 > tiff.len) return null;

    const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
    const ifd1_usize: usize = ifd1_off;
    if (ifd1_usize == 0 or ifd1_usize + 2 > tiff.len) return null;

    const num_ifd1_entries = if (is_le) std.mem.readInt(u16, tiff[ifd1_usize..][0..2], .little) else std.mem.readInt(u16, tiff[ifd1_usize..][0..2], .big);
    var entry_off = ifd1_usize + 2;

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

/// Pair of extracted preview and thumbnail locations from a RAW image container.
pub const RawPreviewCandidates = struct {
    preview: ?ThumbnailLocation = null,
    thumbnail: ?ThumbnailLocation = null,
};

/// Extracts the largest embedded JPEG preview location and smallest thumbnail location from a TIFF-based RAW container.
pub fn extractTiffRawPreviews(data: []const u8) RawPreviewCandidates {
    const header = findTiffPayload(data) orelse return .{};
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;
    const tiff_start_off = @intFromPtr(tiff.ptr) - @intFromPtr(data.ptr);

    const Candidate = struct { off: u32, len: u32 };
    var candidates: [16]Candidate = undefined;
    var cand_count: usize = 0;

    const parseIfdForJpegs = struct {
        fn run(
            t: []const u8,
            off: usize,
            le: bool,
            cands: []Candidate,
            count: *usize,
            sub_ifds: ?*SubIfdList,
        ) error{TooManySubIfds}!void {
            if (off >= t.len or off + 2 > t.len) return;
            const num = if (le) std.mem.readInt(u16, t[off..][0..2], .little) else std.mem.readInt(u16, t[off..][0..2], .big);
            var entry_off = off + 2;
            var i: usize = 0;
            var j_off: ?u32 = null;
            var j_len: ?u32 = null;

            while (i < num) : (i += 1) {
                if (entry_off + 12 > t.len) break;
                const entry = t[entry_off .. entry_off + 12];
                entry_off += 12;

                const tag = if (le) std.mem.readInt(u16, entry[0..2][0..2], .little) else std.mem.readInt(u16, entry[0..2][0..2], .big);
                const type_id = if (le) std.mem.readInt(u16, entry[2..4][0..2], .little) else std.mem.readInt(u16, entry[2..4][0..2], .big);
                const val_count = if (le) std.mem.readInt(u32, entry[4..8][0..4], .little) else std.mem.readInt(u32, entry[4..8][0..4], .big);

                if (tag == 0x0201) {
                    j_off = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                } else if (tag == 0x0202) {
                    j_len = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                } else if (tag == 0x014A and sub_ifds != null) {
                    if (val_count == 1) {
                        const s_off = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                        if (s_off > 0) try sub_ifds.?.append(s_off);
                    } else if (val_count > 1 and (type_id == 4 or type_id == 13)) {
                        if (val_count > 8) return error.TooManySubIfds;
                        const ptr_off = if (le) std.mem.readInt(u32, entry[8..12][0..4], .little) else std.mem.readInt(u32, entry[8..12][0..4], .big);
                        if (ptr_off < t.len) {
                            var s_idx: usize = 0;
                            while (s_idx < val_count) : (s_idx += 1) {
                                const read_pos = @as(usize, ptr_off) + s_idx * 4;
                                if (read_pos + 4 <= t.len) {
                                    const s_off = if (le) std.mem.readInt(u32, t[read_pos .. read_pos + 4][0..4], .little) else std.mem.readInt(u32, t[read_pos .. read_pos + 4][0..4], .big);
                                    if (s_off > 0) try sub_ifds.?.append(s_off);
                                }
                            }
                        }
                    }
                }
            }

            if (j_off != null and j_len != null and j_len.? > 0) {
                if (count.* < cands.len) {
                    cands[count.*] = .{ .off = j_off.?, .len = j_len.? };
                    count.* += 1;
                }
            }
        }
    }.run;

    var sub_ifd_list: SubIfdList = .{};

    // 1. Parse IFD0
    parseIfdForJpegs(tiff, ifd0_off, is_le, &candidates, &cand_count, &sub_ifd_list) catch |err| {
        std.log.err("extractTiffRawPreviews: failed to parse IFD0: {}", .{err});
        return .{};
    };

    // 2. Parse SubIFDs
    for (sub_ifd_list.slice()) |s_off| {
        parseIfdForJpegs(tiff, s_off, is_le, &candidates, &cand_count, null) catch |err| {
            std.log.warn("extractTiffRawPreviews: failed to parse SubIFD at offset {d}: {}", .{ s_off, err });
        };
    }

    // 3. Parse IFD1
    const num_ifd0_entries = if (is_le) std.mem.readInt(u16, tiff[ifd0_off..][0..2], .little) else std.mem.readInt(u16, tiff[ifd0_off..][0..2], .big);
    const ifd1_ptr_off = @as(usize, ifd0_off) + 2 + @as(usize, num_ifd0_entries) * 12;
    if (ifd1_ptr_off + 4 <= tiff.len) {
        const ifd1_off = if (is_le) std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .little) else std.mem.readInt(u32, tiff[ifd1_ptr_off..][0..4], .big);
        if (ifd1_off > 0 and ifd1_off < tiff.len) {
            parseIfdForJpegs(tiff, ifd1_off, is_le, &candidates, &cand_count, null) catch |err| {
                std.log.warn("extractTiffRawPreviews: failed to parse IFD1 at offset {d}: {}", .{ ifd1_off, err });
            };
        }
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

    return .{
        .preview = .{
            .file_offset = tiff_start_off + @as(u64, prev_c.off),
            .length = prev_c.len,
        },
        .thumbnail = .{
            .file_offset = tiff_start_off + @as(u64, thumb_c.off),
            .length = thumb_c.len,
        },
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

test "SubIfdList capacity and error on overflow" {
    var list = SubIfdList{};
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try list.append(100 + i);
    }
    try std.testing.expectEqual(@as(usize, 8), list.len);
    try std.testing.expectEqual(@as(usize, 8), list.slice().len);

    // 9th element triggers error.TooManySubIfds to halt parsing corrupt metadata
    try std.testing.expectError(error.TooManySubIfds, list.append(999));
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
    std.mem.writeInt(u32, buf[16..20][0..4], 8, .little); // IFD0 at offset 8 (relative to TIFF start at 12 -> index 20)

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
