const geom = @import("geom");
const std = @import("std");

const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;

/// 4-state orthogonal image orientation enum (0°, 90°, 180°, 270°).
///
/// Collapses TIFF EXIF tags 1..8 into the 4 orthogonal rotation states
/// supported by the viewer. Provides branchless scalar degree conversion
/// and dimension swap checks.
pub const Orientation = enum(u2) {
    normal = 0,
    rotate_90 = 1,
    rotate_180 = 2,
    rotate_270 = 3,

    /// Maps TIFF 6.0 / EXIF 2.32 orientation tag values (1..8) to the 4
    /// orthogonal rotation states.
    pub fn fromTiff(val: u16) Orientation {
        return switch (val) {
            6, 7 => .rotate_90,
            3, 4 => .rotate_180,
            8, 5 => .rotate_270,
            else => .normal,
        };
    }

    /// Direct branchless arithmetic conversion to floating-point degrees:
    /// index * 90.0.
    pub inline fn toDegrees(self: Orientation) f32 {
        return @as(f32, @floatFromInt(@backingInt(self))) * 90.0;
    }

    /// Branchless bitwise check: odd indices (1 and 3) swap width and height.
    pub inline fn isDimensionSwapped(self: Orientation) bool {
        return (@backingInt(self) & 1) != 0;
    }
};

/// RAW camera sensor metadata variant eliminating impossible states
/// (e.g. RAW flag without valid dimensions).
pub const RawMetadata = union(enum) {
    none,
    raw: struct {
        sensor_w: f32,
        sensor_h: f32,
    },

    /// Safely constructs a RawMetadata variant, guaranteeing strictly positive
    /// finite dimensions.
    pub fn init(sensor_w: f32, sensor_h: f32) RawMetadata {
        if (sensor_w > 0.0 and sensor_h > 0.0 and
            std.math.isFinite(sensor_w) and std.math.isFinite(sensor_h))
        {
            return .{ .raw = .{ .sensor_w = sensor_w, .sensor_h = sensor_h } };
        }
        return .none;
    }

    /// Returns `true` if this media entry is a Camera RAW file with valid
    /// embedded preview.
    pub inline fn isRaw(self: RawMetadata) bool {
        return self == .raw;
    }

    /// Returns true sensor dimensions if RAW, or `null` if standard media
    /// format.
    pub inline fn getSensorDims(self: RawMetadata) ?PhysicalDims {
        return switch (self) {
            .raw => |r| if (r.sensor_w > 0.0 and r.sensor_h > 0.0)
                .{ .w = r.sensor_w, .h = r.sensor_h }
            else
                null,
            .none => null,
        };
    }
};

/// Container metadata discovered synchronously by probing file headers
/// on the main thread (< 0.1ms).
pub const ProbedImageMetadata = struct {
    dims: PhysicalDims,
    /// Image orientation metadata.
    orientation: Orientation = .normal,
    raw_metadata: RawMetadata = .none,
    /// True if an embedded preview thumbnail was discovered in container
    /// headers.
    has_embedded_thumbnail: bool = false,
};

/// Identifies image MIME container type using magic bytes from header buffer,
/// falling back to file extension matching if magic bytes are ambiguous.
pub fn detectMimeType(header: []const u8, path: []const u8) []const u8 {
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (header.len >= 8 and std.mem.startsWith(u8, header, &png_magic)) {
        return "image/png";
    }
    if (header.len >= 3 and
        std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF }))
    {
        return "image/jpeg";
    }
    if (header.len >= 6 and
        (std.mem.startsWith(u8, header, "GIF87a") or
            std.mem.startsWith(u8, header, "GIF89a")))
    {
        return "image/gif";
    }
    if (header.len >= 2 and std.mem.startsWith(u8, header, "BM")) {
        return "image/bmp";
    }
    if (header.len >= 12 and
        std.mem.startsWith(u8, header, "RIFF") and
        std.mem.eql(u8, header[8..12], "WEBP"))
    {
        return "image/webp";
    }
    if (header.len >= 8 and std.mem.startsWith(u8, header, "FUJIFILM")) {
        return "image/x-fuji-raf";
    }
    if (header.len >= 4) {
        const is_tiff_le = header[0] == 0x49 and header[1] == 0x49 and
            header[2] == 0x2A and header[3] == 0x00;
        const is_tiff_be = header[0] == 0x4D and header[1] == 0x4D and
            header[2] == 0x00 and header[3] == 0x2A;
        if (is_tiff_le or is_tiff_be) {
            const ext = std.Io.Dir.path.extension(path);
            if (std.ascii.eqlIgnoreCase(ext, ".arw")) return "image/x-sony-arw";
            if (std.ascii.eqlIgnoreCase(ext, ".cr2"))
                return "image/x-canon-cr2";
            if (std.ascii.eqlIgnoreCase(ext, ".nef"))
                return "image/x-nikon-nef";
            if (std.ascii.eqlIgnoreCase(ext, ".dng"))
                return "image/x-adobe-dng";
            if (std.ascii.eqlIgnoreCase(ext, ".orf"))
                return "image/x-olympus-orf";
            if (std.ascii.eqlIgnoreCase(ext, ".rw2"))
                return "image/x-panasonic-rw2";
            if (std.ascii.eqlIgnoreCase(ext, ".pef"))
                return "image/x-pentax-pef";
            return "image/tiff";
        }
    }

    const ext = std.Io.Dir.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg"))
    {
        return "image/jpeg";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".tga")) return "image/x-tga";
    if (std.ascii.eqlIgnoreCase(ext, ".raf")) return "image/x-fuji-raf";
    if (std.ascii.eqlIgnoreCase(ext, ".arw")) return "image/x-sony-arw";
    if (std.ascii.eqlIgnoreCase(ext, ".cr2")) return "image/x-canon-cr2";
    if (std.ascii.eqlIgnoreCase(ext, ".nef")) return "image/x-nikon-nef";
    if (std.ascii.eqlIgnoreCase(ext, ".dng")) return "image/x-adobe-dng";
    if (std.ascii.eqlIgnoreCase(ext, ".orf")) return "image/x-olympus-orf";
    if (std.ascii.eqlIgnoreCase(ext, ".rw2")) return "image/x-panasonic-rw2";
    if (std.ascii.eqlIgnoreCase(ext, ".pef")) return "image/x-pentax-pef";

    return "unknown";
}

/// Returns true when `mime_type` is `"image/x-fuji-raf"` or `header_slice`
/// begins with the `"FUJIFILM"` magic signature.
pub fn isFujiRafHeader(
    header_slice: []const u8,
    mime_type: []const u8,
) bool {
    return std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
        (header_slice.len >= 8 and
            std.mem.startsWith(u8, header_slice, "FUJIFILM"));
}

/// Returns true when `header_slice` or `mime_type` represents a Camera RAW
/// container (Fujifilm RAF or `image/x-*` format).
pub inline fn isRawContainer(
    header_slice: []const u8,
    mime_type: []const u8,
) bool {
    return isFujiRafHeader(header_slice, mime_type) or
        std.mem.startsWith(u8, mime_type, "image/x-");
}

/// Advances past a ZIP `LocalFileHeader` (plus variable-length filename
/// and extra fields) at the start of `buf` if present, returning the
/// remaining payload slice or `null` when `buf` is empty or truncated.
pub fn skipZipLocalFileHeader(buf: []const u8) ?[]const u8 {
    if (buf.len == 0) return null;
    var data_offset: usize = 0;
    if (buf.len >= @sizeOf(std.zip.LocalFileHeader) and
        std.mem.eql(u8, buf[0..4], &std.zip.local_file_header_sig))
    {
        const filename_len = std.mem.readInt(u16, buf[26..28], .little);
        const extra_len = std.mem.readInt(u16, buf[28..30], .little);
        data_offset = @sizeOf(std.zip.LocalFileHeader) +|
            @as(usize, filename_len) +|
            @as(usize, extra_len);
    }
    if (buf.len <= data_offset) return null;
    return buf[data_offset..];
}

/// Parses full image width and height directly from image container headers
/// (JPEG, PNG, GIF, WebP, BMP, TIFF, RAW) in < 0.05ms without decompression.
///
/// Returns null if header buffer is insufficient or contains unsupported
/// format.
pub fn parseImageDimensions(
    header: []const u8,
    mime_type: []const u8,
) ?PhysicalDims {
    if (isFujiRafHeader(header, mime_type)) {
        if (extractFujiRafMetadataLocation(header)) |meta_loc| {
            if (meta_loc.file_offset +| meta_loc.length <= header.len) {
                const off: usize = @intCast(meta_loc.file_offset);
                const len: usize = @intCast(meta_loc.length);
                if (parseFujiRafDimensions(header[off .. off + len])) |d| {
                    return d;
                }
            }
        }
        if (extractFujiRafPreviewLocation(header)) |prev_loc| {
            if (prev_loc.file_offset +| 32 <= header.len) {
                const off: usize = @intCast(prev_loc.file_offset);
                if (readJpegDimensions(header[off..])) |d| {
                    return d;
                }
            }
        }
    } else if (std.mem.startsWith(u8, mime_type, "image/x-") or
        std.mem.eql(u8, mime_type, "image/tiff") or
        (header.len >= 4 and ((header[0] == 0x49 and header[1] == 0x49 and
            header[2] == 0x2A and header[3] == 0x00) or
            (header[0] == 0x4D and header[1] == 0x4D and
                header[2] == 0x00 and header[3] == 0x2A))))
    {
        if (parseExifDimensions(header)) |d| return d;
    } else if (std.mem.eql(u8, mime_type, "image/jpeg") or
        (header.len >= 3 and
            std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF })))
    {
        if (readJpegDimensions(header)) |d| return d;
    } else if (std.mem.eql(u8, mime_type, "image/png") or
        (header.len >= 8 and
            std.mem.startsWith(
                u8,
                header,
                &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A },
            )))
    {
        const is_png = header.len >= 24 and
            std.mem.startsWith(
                u8,
                header,
                &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A },
            ) and
            std.mem.eql(u8, header[12..16], "IHDR");
        if (is_png) {
            const w = std.mem.readInt(u32, header[16..20], .big);
            const h = std.mem.readInt(u32, header[20..24], .big);
            if (w > 0 and h > 0) {
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            }
        }
    } else if (std.mem.eql(u8, mime_type, "image/gif") or
        (header.len >= 6 and
            (std.mem.startsWith(u8, header, "GIF87a") or
                std.mem.startsWith(u8, header, "GIF89a"))))
    {
        const is_gif = header.len >= 10 and
            (std.mem.startsWith(u8, header, "GIF87a") or
                std.mem.startsWith(u8, header, "GIF89a"));
        if (is_gif) {
            const w = std.mem.readInt(u16, header[6..8], .little);
            const h = std.mem.readInt(u16, header[8..10], .little);
            if (w > 0 and h > 0) {
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            }
        }
    } else if (std.mem.eql(u8, mime_type, "image/webp") or
        (header.len >= 12 and
            std.mem.startsWith(u8, header, "RIFF") and
            std.mem.eql(u8, header[8..12], "WEBP")))
    {
        if (header.len >= 25 and
            std.mem.startsWith(u8, header, "RIFF") and
            std.mem.eql(u8, header[8..12], "WEBP"))
        {
            if (std.mem.eql(u8, header[12..16], "VP8X") and header.len >= 30) {
                const w = 1 + (@as(u32, header[24]) |
                    (@as(u32, header[25]) << 8) |
                    (@as(u32, header[26]) << 16));
                const h = 1 + (@as(u32, header[27]) |
                    (@as(u32, header[28]) << 8) |
                    (@as(u32, header[29]) << 16));
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else if (std.mem.eql(u8, header[12..16], "VP8L") and
                header.len >= 25 and
                header[20] == 0x2F)
            {
                const b0: u32 = header[21];
                const b1: u32 = header[22];
                const b2: u32 = header[23];
                const b3: u32 = header[24];
                const bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                const w = 1 + (bits & 0x3FFF);
                const h = 1 + ((bits >> 14) & 0x3FFF);
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else if (std.mem.eql(u8, header[12..16], "VP8 ") and
                header.len >= 30)
            {
                if (header[23] == 0x9D and
                    header[24] == 0x01 and
                    header[25] == 0x2A)
                {
                    const w = std.mem.readInt(
                        u16,
                        header[26..28],
                        .little,
                    ) & 0x3FFF;
                    const h = std.mem.readInt(
                        u16,
                        header[28..30],
                        .little,
                    ) & 0x3FFF;
                    if (w > 0 and h > 0) {
                        return .{
                            .w = @floatFromInt(w),
                            .h = @floatFromInt(h),
                        };
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, mime_type, "image/bmp") or
        (header.len >= 2 and std.mem.startsWith(u8, header, "BM")))
    {
        if (header.len >= 26 and std.mem.startsWith(u8, header, "BM")) {
            const dib_size = std.mem.readInt(u32, header[14..18], .little);
            if (dib_size >= 40 and header.len >= 26) {
                const w = std.mem.readInt(i32, header[18..22], .little);
                const h = std.mem.readInt(i32, header[22..26], .little);
                if (w != std.math.minInt(i32) and
                    h != std.math.minInt(i32))
                {
                    const abs_w: u32 = @intCast(if (w < 0) -w else w);
                    const abs_h: u32 = @intCast(if (h < 0) -h else h);
                    if (abs_w > 0 and abs_h > 0) {
                        return .{
                            .w = @floatFromInt(abs_w),
                            .h = @floatFromInt(abs_h),
                        };
                    }
                }
            }
        }
    }
    return null;
}

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

/// Canonical TIFF tag IDs per TIFF 6.0, TIFF-EP (ISO 12234-2),
/// EXIF 2.32, and Adobe DNG specifications.
const TiffTag = enum(u16) {
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

    /// Converts a raw 16-bit TIFF tag identifier to `TiffTag`.
    inline fn fromInt(val: u16) TiffTag {
        return @fromBackingInt(val);
    }
};

/// Bitflags for TIFF tag 0x00FE (`NewSubfileType`).
/// Defined in TIFF 6.0 Section 6 (p. 36) and Adobe DNG Specification Section 2.
const NewSubfileType = struct {
    /// Primary full-resolution image (raw Bayer sensor CFA array in RAW
    /// containers).
    const FULL_RESOLUTION: u32 = 0x00000000;
    /// Reduced-resolution version of another image in this file
    /// (thumbnail or medium preview).
    const REDUCED_IMAGE: u32 = 0x00000001;
    /// Multi-page document page.
    const PAGE: u32 = 0x00000002;
    /// Transparency / alpha mask.
    const MASK: u32 = 0x00000004;
    /// Alternative processed preview image (Adobe DNG 1.2+).
    const PREVIEW_IMAGE: u32 = 0x00010000;

    /// Checks if this subfile represents a reduced-resolution preview or
    /// thumbnail.
    inline fn isReducedImage(val: u32) bool {
        return (val & REDUCED_IMAGE) != 0;
    }
};

/// PhotometricInterpretation values per TIFF 6.0 and TIFF-EP.
const Photometric = enum(u16) {
    black_is_zero = 1,
    rgb = 2,
    ycbcr = 6,
    cfa = 32803,
    linear_raw = 34892,
    _,
};

/// Compression values per TIFF 6.0 and TIFF-EP.
const Compression = enum(u16) {
    uncompressed = 1,
    jpeg_old = 6,
    jpeg = 7,
    sony_arw = 32767,
    _,
};

/// Segmented TIFF source for zero-allocation parsing of files where the root
/// IFD0 directory is located at the tail of the file rather than the initial
/// header.
const TiffSource = struct {
    header: []const u8,
    tail_offset: u64 = 0,
    tail: []const u8 = "",

    /// Initializes a TIFF source wrapping a single contiguous header slice.
    inline fn init(header: []const u8) TiffSource {
        return .{ .header = header };
    }

    /// Initializes a TIFF source wrapping a header slice and a tail slice
    /// loaded from `tail_offset` in the source file.
    inline fn initWithTail(
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

    /// Retrieves a contiguous slice of `len` bytes starting at `off` from
    /// either the header or tail buffer, or `null` if unavailable.
    inline fn getSlice(
        self: TiffSource,
        off: usize,
        len: usize,
    ) ?[]const u8 {
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
fn probeTiffIfd0Offset(header: []const u8) ?u32 {
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
fn readTiffSource(
    io: std.Io,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
    tail_buf: []u8,
) TiffSource {
    if (probeTiffIfd0Offset(header_slice)) |ifd0_off| {
        if (ifd0_off >= header_slice.len and ifd0_off < file_size) {
            const tail_target: usize = @intCast(
                @min(file_size - ifd0_off, tail_buf.len),
            );
            if (tail_target > 0) {
                var t_slices = [_][]u8{tail_buf[0..tail_target]};
                const tn = file.readPositional(io, &t_slices, ifd0_off) catch 0;
                if (tn > 0) {
                    return TiffSource.initWithTail(
                        header_slice,
                        ifd0_off,
                        tail_buf[0..tn],
                    );
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
        if (std.mem.eql(u8, h8[0..2], "II") or
            std.mem.eql(u8, h8[0..2], "MM"))
        {
            const is_le = (h8[0] == 'I');
            const sig = readU16(h8[2..4][0..2], is_le);
            if (sig == 0x002A) {
                const ifd0_off = readU32(h8[4..8][0..4], is_le);
                const off: usize = ifd0_off;
                if (off >= 8 and
                    (off & 1) == 0 and
                    source.getSlice(off, 2) != null)
                {
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
        while (marker_offset < source.header.len and
            source.header[marker_offset] == 0xFF)
        {
            marker_offset += 1;
        }
        if (marker_offset >= source.header.len) break;
        const marker = source.header[marker_offset];
        idx = marker_offset + 1;

        if (marker == 0xD9 or marker == 0xDA) break;

        if (idx + 2 > source.header.len) break;
        const seg_len = (@as(usize, source.header[idx]) << 8) |
            @as(usize, source.header[idx + 1]);
        if (seg_len < 2) break;

        const available_len = @min(seg_len, source.header.len - idx);
        const payload = source.header[idx + 2 .. idx + available_len];

        if (marker == 0xE1) {
            if (payload.len >= 14 and
                std.mem.startsWith(u8, payload, "Exif\x00\x00"))
            {
                const tiff = payload[6..];
                if (tiff.len < 8) continue;

                const is_le = if (std.mem.eql(u8, tiff[0..2], "II"))
                    true
                else if (std.mem.eql(u8, tiff[0..2], "MM"))
                    false
                else
                    continue;

                const sig = readU16(tiff[2..4][0..2], is_le);
                if (sig != 0x002A) continue;

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

        if (idx + seg_len > source.header.len) break;
        idx += seg_len;
    }
    return null;
}

fn findTiffPayload(data: []const u8) ?TiffHeader {
    // 1. Direct TIFF container (Sony ARW, DNG, CR2, NEF, ORF, RW2, PEF, etc.)
    if (data.len >= 8) {
        if (std.mem.eql(u8, data[0..2], "II") or
            std.mem.eql(u8, data[0..2], "MM"))
        {
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
        const seg_len = (@as(usize, data[idx]) << 8) |
            @as(usize, data[idx + 1]);
        if (seg_len < 2) break;

        const available_len = @min(seg_len, data.len - idx);
        const payload = data[idx + 2 .. idx + available_len];

        if (marker == 0xE1) {
            if (payload.len >= 14 and
                std.mem.startsWith(u8, payload, "Exif\x00\x00"))
            {
                const tiff = payload[6..];
                if (tiff.len < 8) continue;

                const is_le = if (std.mem.eql(u8, tiff[0..2], "II"))
                    true
                else if (std.mem.eql(u8, tiff[0..2], "MM"))
                    false
                else
                    continue;

                const sig = readU16(tiff[2..4][0..2], is_le);
                if (sig != 0x002A) continue;

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

        if (idx + seg_len > data.len) break;
        idx += seg_len;
    }
    return null;
}

const SubIfdList = struct {
    items: [8]u32 = undefined,
    len: usize = 0,

    fn append(self: *SubIfdList, item: u32) void {
        if (self.len < self.items.len) {
            self.items[self.len] = item;
            self.len += 1;
        }
    }

    fn slice(self: *const SubIfdList) []const u32 {
        return self.items[0..self.len];
    }
};

fn collectSubIfdOffsets(
    s: TiffSource,
    val_or_ptr: u32,
    count: usize,
    type_id: u16,
    le: bool,
    sub_ifds: *SubIfdList,
) void {
    if (count == 1) {
        if (val_or_ptr > 0) sub_ifds.append(val_or_ptr);
    } else if (count > 1 and (type_id == 4 or type_id == 13)) {
        const fetch_count = @min(count, 8);
        var s_idx: usize = 0;
        while (s_idx < fetch_count) : (s_idx += 1) {
            const read_pos = std.math.add(
                usize,
                @as(usize, val_or_ptr),
                s_idx * 4,
            ) catch break;
            const s_slice = s.getSlice(read_pos, 4) orelse continue;
            const s_off = readU32(s_slice[0..4], le);
            if (s_off > 0) sub_ifds.append(s_off);
        }
    }
}

const PreviewCandidate = struct { off: u32, len: u32 };

fn extractDngPrivatePreview(
    s: TiffSource,
    val_or_off: u32,
    val_count: usize,
) ?PreviewCandidate {
    if (val_count < 70) return null;
    const p_slice = s.getSlice(val_or_off, 70) orelse return null;
    if (!std.mem.startsWith(u8, p_slice, "RICOH\x00II") and
        !std.mem.startsWith(u8, p_slice, "PENTAX\x00II"))
    {
        return null;
    }
    // MakerNote explicitly asserts "II" (Little Endian)
    const p_len = std.mem.readInt(u32, p_slice[54..58][0..4], .little);
    const p_rel_off = std.mem.readInt(u32, p_slice[66..70][0..4], .little);
    const is_valid_len = p_len > 0 and p_len < 512 * 1024;
    const is_in_bounds = @as(u64, p_rel_off) + p_len <= val_count;
    if (!is_valid_len or !is_in_bounds) return null;
    const mn_jpeg_off = std.math.add(u32, val_or_off, p_rel_off) catch
        return null;
    return .{ .off = mn_jpeg_off, .len = p_len };
}

/// Parses image pixel dimensions from EXIF TIFF metadata tags (IFD0, ExifIFD,
/// or SubIFD).
fn parseExifDimensions(data: []const u8) ?PhysicalDims {
    return parseExifDimensionsFromSource(TiffSource.init(data));
}

/// Parses image pixel dimensions from a segmented TiffSource.
fn parseExifDimensionsFromSource(source: TiffSource) ?PhysicalDims {
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

                const tag = TiffTag.fromInt(readU16(entry[0..2][0..2], le));
                const type_id = readU16(entry[2..4][0..2], le);
                const count = readU32(entry[4..8][0..4], le);

                var val: u32 = 0;
                if (type_id == 3) {
                    val = readU16(entry[8..10][0..2], le);
                } else if (type_id == 4 or type_id == 13) {
                    val = readU32(entry[8..12][0..4], le);
                }

                if (tag == .new_subfile_type) {
                    subfile_type = val;
                } else if (tag == .photometric_interpretation) {
                    photometric = std.math.cast(u16, val);
                } else if (tag == .image_width or
                    tag == .pixel_x_dimension)
                {
                    cur_w = val;
                } else if (tag == .image_length or
                    tag == .pixel_y_dimension)
                {
                    cur_h = val;
                } else if (tag == .exif_ifd and
                    sub_out != null)
                {
                    sub_out.?.* = val;
                } else if (tag == .sub_ifds and
                    sub_ifds != null)
                {
                    collectSubIfdOffsets(
                        s,
                        val,
                        count,
                        type_id,
                        le,
                        sub_ifds.?,
                    );
                }
            }

            // Reject raw Bayer sensor streams:
            // 1. CFA Bayer (32803) or LinearRaw (34892)
            // 2. Primary raw sensor SubIFDs (!isReducedImage inside SubIFD)
            // 3. Canon CR2 IFD2/IFD3 raw sensor slices
            const is_raw_cfa = (photometric != null and
                (photometric.? == @backingInt(Photometric.cfa) or
                    photometric.? == @backingInt(Photometric.linear_raw)));
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
    // Stack array avoids heap allocation; bounded by loop limit
    // (ifd_depth < 8).
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
        return PhysicalDims{
            .w = @floatFromInt(best_w.?),
            .h = @floatFromInt(best_h.?),
        };
    }
    return null;
}

/// Reads image dimensions from EXIF metadata or scans JPEG Start-of-Frame
/// (SOF) markers.
fn readJpegDimensions(data: []const u8) ?PhysicalDims {
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
        const seg_len = (@as(usize, data[idx]) << 8) |
            @as(usize, data[idx + 1]);
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
                const h = (@as(u16, data[idx + 3]) << 8) |
                    @as(u16, data[idx + 4]);
                const w = (@as(u16, data[idx + 5]) << 8) |
                    @as(u16, data[idx + 6]);
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
fn isLosslessJpeg(data: []const u8) bool {
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
        const seg_len = (@as(usize, data[idx]) << 8) |
            @as(usize, data[idx + 1]);
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
fn parseExifOrientationFromSource(source: TiffSource) ?Orientation {
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

        const tag = TiffTag.fromInt(readU16(entry[0..2][0..2], is_le));
        if (tag == .orientation) {
            const val = readU16(entry[8..10][0..2], is_le);
            return Orientation.fromTiff(val);
        }
    }
    return null;
}

/// Reads the EXIF orientation tag by reading the header of a JPEG file on disk.
pub fn readJpegExifOrientation(io: std.Io, path: []const u8) ?Orientation {
    const ext = std.Io.Dir.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".jpg") and
        !std.ascii.eqlIgnoreCase(ext, ".jpeg")) return null;

    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        path,
        .{},
    ) catch |err| {
        std.log.debug(
            "readJpegExifOrientation: openFile failed for '{s}': {}",
            .{ path, err },
        );
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

    /// Returns `buf[file_offset .. file_offset + length]` when the range
    /// is non-empty and fits within `buf`, or `null` otherwise.
    pub inline fn sliceInBounds(
        self: ThumbnailLocation,
        buf: []const u8,
    ) ?[]const u8 {
        if (self.length == 0) return null;
        if (self.file_offset +| self.length > buf.len) return null;
        const start: usize = @intCast(self.file_offset);
        const end: usize = @intCast(self.file_offset + self.length);
        return buf[start..end];
    }

    /// Returns `true` when `length > 0`, `file_offset + length <= file_size`,
    /// and `length` does not exceed `max_bytes` (when specified).
    pub inline fn isValid(
        self: ThumbnailLocation,
        file_size: u64,
        max_bytes: ?u32,
    ) bool {
        if (self.length == 0) return false;
        if (max_bytes) |limit| {
            if (self.length > limit) return false;
        }
        const end = std.math.add(u64, self.file_offset, self.length) catch
            return false;
        return end <= file_size;
    }
};

/// Locates the byte offset and length of an embedded JPEG thumbnail in IFD1
/// without allocating memory.
pub fn extractJpegThumbnailLocation(data: []const u8) ?ThumbnailLocation {
    const header = findTiffPayload(data) orelse return null;
    const tiff = header.tiff;
    const is_le = header.is_le;
    const ifd0_off = header.ifd0_off;

    const num_ifd0_entries = readU16(tiff[ifd0_off..][0..2], is_le);
    const ifd1_ptr_off = @as(usize, ifd0_off) +| 2 +|
        @as(usize, num_ifd0_entries) *| 12;
    if (ifd1_ptr_off +| 4 > tiff.len) return null;

    const ifd1_off = readU32(tiff[ifd1_ptr_off..][0..4], is_le);
    const ifd1_usize = std.math.cast(usize, ifd1_off) orelse return null;
    if (ifd1_usize == 0 or ifd1_usize +| 2 > tiff.len) return null;

    const num_ifd1_entries = readU16(tiff[ifd1_usize..][0..2], is_le);
    var entry_off = ifd1_usize + 2;

    var thumb_off: ?u32 = null;
    var thumb_len: ?u32 = null;

    var i: usize = 0;
    while (i < num_ifd1_entries) : (i += 1) {
        if (entry_off +| 12 > tiff.len) break;
        const entry = tiff[entry_off .. entry_off + 12];
        entry_off += 12;

        const tag = TiffTag.fromInt(readU16(entry[0..2][0..2], is_le));
        if (tag == .jpeg_interchange_format) {
            thumb_off = readU32(entry[8..12][0..4], is_le);
        } else if (tag == .jpeg_interchange_format_length) {
            thumb_len = readU32(entry[8..12][0..4], is_le);
        }
    }

    if (thumb_off != null and thumb_len != null and thumb_len.? > 0) {
        const tiff_start_off = @intFromPtr(tiff.ptr) - @intFromPtr(data.ptr);
        return .{
            .file_offset = tiff_start_off +| @as(u64, thumb_off.?),
            .length = thumb_len.?,
        };
    }
    return null;
}

/// Extracts and bounds-checks the IFD1 embedded JPEG thumbnail location
/// when `mime_type` is `"image/jpeg"`.
pub fn extractValidJpegThumbnailLocation(
    header_slice: []const u8,
    mime_type: []const u8,
    file_size: u64,
    max_bytes: ?u32,
) ?ThumbnailLocation {
    if (!std.mem.eql(u8, mime_type, "image/jpeg")) return null;
    const loc = extractJpegThumbnailLocation(header_slice) orelse
        return null;
    return if (loc.isValid(file_size, max_bytes)) loc else null;
}

/// Set of extracted preview, medium-res preview, and thumbnail locations from
/// a RAW container.
const RawPreviewCandidates = struct {
    preview: ?ThumbnailLocation = null,
    medium: ?ThumbnailLocation = null,
    thumbnail: ?ThumbnailLocation = null,
};

/// Extracts the largest embedded JPEG preview location and smallest thumbnail
/// location from a TIFF-based RAW container.
fn extractTiffRawPreviews(data: []const u8) RawPreviewCandidates {
    return extractTiffRawPreviewsFromSource(TiffSource.init(data));
}

/// Extracts the largest embedded JPEG preview location and smallest thumbnail
/// location from a segmented TiffSource.
fn extractTiffRawPreviewsFromSource(
    source: TiffSource,
) RawPreviewCandidates {
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

    const Candidate = PreviewCandidate;
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

                const tag = TiffTag.fromInt(readU16(entry[0..2][0..2], le));
                const type_id = readU16(entry[2..4][0..2], le);
                const val_count = readU32(entry[4..8][0..4], le);

                if (tag == .new_subfile_type) {
                    subfile_type = if (type_id == 3)
                        readU16(entry[8..10][0..2], le)
                    else
                        readU32(entry[8..12][0..4], le);
                } else if (tag == .compression) {
                    compression = readU16(entry[8..10][0..2], le);
                } else if (tag == .photometric_interpretation) {
                    photometric = readU16(entry[8..10][0..2], le);
                } else if (tag == .planar_configuration) {
                    planar_config = readU16(entry[8..10][0..2], le);
                } else if (tag == .cr2_slice or
                    tag == .cr2_raw_image_data or
                    tag == .cr2_sensor_info or
                    tag == .cr2_offsets)
                {
                    is_cr2_raw_ifd = true;
                } else if (tag == .strip_offsets) {
                    // Per DNG Spec / TIFF-EP, embedded JPEG previews must be a
                    // single contiguous bitstream
                    if (val_count == 1) {
                        strip_off = if (type_id == 3)
                            readU16(entry[8..10][0..2], le)
                        else
                            readU32(entry[8..12][0..4], le);
                    }
                } else if (tag == .strip_byte_counts) {
                    if (val_count == 1) {
                        strip_len = if (type_id == 3)
                            readU16(entry[8..10][0..2], le)
                        else
                            readU32(entry[8..12][0..4], le);
                    }
                } else if (tag == .jpeg_interchange_format) {
                    j_off = readU32(entry[8..12][0..4], le);
                } else if (tag == .jpeg_interchange_format_length) {
                    j_len = readU32(entry[8..12][0..4], le);
                } else if (tag == .dng_private_data) {
                    const val_or_off = readU32(entry[8..12][0..4], le);
                    if (extractDngPrivatePreview(
                        s,
                        val_or_off,
                        val_count,
                    )) |cand| {
                        if (count.* < cands.len) {
                            cands[count.*] = cand;
                            count.* += 1;
                        }
                    }
                } else if (tag == .sub_ifds and
                    sub_ifds != null)
                {
                    const val_or_ptr = readU32(entry[8..12][0..4], le);
                    collectSubIfdOffsets(
                        s,
                        val_or_ptr,
                        val_count,
                        type_id,
                        le,
                        sub_ifds.?,
                    );
                }
            }

            if (j_off != null and
                j_len != null and
                j_off.? > 0 and
                j_len.? > 0)
            {
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
                    (compression.? == @backingInt(Compression.jpeg_old) or
                        compression.? == @backingInt(Compression.jpeg)));
                // Standard JPEG preview photometrics (6 = YCbCr, 2 = RGB,
                // 1 = BlackIsZero, or null).
                // Specifically excludes 32803 (CFA Bayer) and 34892
                // (LinearRaw).
                const is_jpeg_color = (photometric == null or
                    photometric.? == @backingInt(Photometric.ycbcr) or
                    photometric.? == @backingInt(Photometric.rgb) or
                    photometric.? == @backingInt(Photometric.black_is_zero));
                const is_bayer_color = (photometric != null and
                    (photometric.? == @backingInt(Photometric.cfa) or
                        photometric.? == @backingInt(Photometric.linear_raw)));
                // Reject full-resolution primary raw sensor streams
                // (NewSubfileType == 0)
                const is_reduced_or_unspecified = (subfile_type == null or
                    NewSubfileType.isReducedImage(subfile_type.?));

                var is_not_jpeg = false;
                var is_lossless_raw = false;

                // In Canon CR2, IFD2 is uncompressed RGB and IFD3 is
                // Bayer raw sensor stream
                if (is_cr2_file and depth >= 2) is_not_jpeg = true;
                if (is_cr2_raw_ifd) is_not_jpeg = true;
                // Reject planar TIFFs (PlanarConfiguration == 2); JPEG
                // strips are always chunky (1)
                if (planar_config != null and planar_config.? == 2)
                    is_not_jpeg = true;

                // Validate SOI marker if strip payload header is
                // accessible in source
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
                    is_reduced_or_unspecified and
                    !is_not_jpeg and
                    !is_lossless_raw)
                {
                    if (std.math.add(u32, strip_off.?, strip_len.?)) |_| {
                        if (count.* < cands.len) {
                            cands[count.*] = .{
                                .off = strip_off.?,
                                .len = strip_len.?,
                            };
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
    // Stack array avoids heap allocation; bounded by loop limit
    // (ifd_depth < 8).
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
            if (c.len > thumb_c.len and
                c.len < prev_c.len and
                c.len <= 2 * 1024 * 1024)
            {
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

/// Reads the embedded preview JPEG byte offset and length from a
/// Fujifilm RAF file header.
fn extractFujiRafPreviewLocation(
    header_bytes: []const u8,
) ?ThumbnailLocation {
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

/// Reads the metadata block byte offset and length from a Fujifilm RAF
/// file header.
fn extractFujiRafMetadataLocation(
    header_bytes: []const u8,
) ?ThumbnailLocation {
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

/// Parses full camera sensor dimensions from the Fujifilm RAF metadata
/// records block.
fn parseFujiRafDimensions(meta_bytes: []const u8) ?PhysicalDims {
    if (meta_bytes.len < 4) return null;
    const num_records = std.mem.readInt(u32, meta_bytes[0..4], .big);
    var pos: usize = 4;

    var cropped_size: ?PhysicalDims = null;
    var image_size: ?PhysicalDims = null;
    var full_size: ?PhysicalDims = null;

    var i: usize = 0;
    while (i < num_records) : (i += 1) {
        if (pos + 4 > meta_bytes.len) break;
        const tag_id = std.mem.readInt(u16, meta_bytes[pos..][0..2], .big);
        const tag_len = std.mem.readInt(
            u16,
            meta_bytes[pos + 2 ..][0..2],
            .big,
        );
        pos += 4;

        if (pos + tag_len > meta_bytes.len) break;
        const tag_data = meta_bytes[pos .. pos + tag_len];
        pos += tag_len;

        if (tag_len >= 4) {
            const h = std.mem.readInt(u16, tag_data[0..2], .big);
            const w = std.mem.readInt(u16, tag_data[2..4], .big);
            if (w > 0 and h > 0) {
                const dims = PhysicalDims{
                    .w = @floatFromInt(w),
                    .h = @floatFromInt(h),
                };
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

/// Unified header-probe result for Camera RAW containers (Fujifilm RAF and
/// TIFF-based RAW formats such as ARW, CR2, NEF, DNG, ORF, RW2, and PEF).
pub const RawHeaderProbe = struct {
    preview: ?ThumbnailLocation = null,
    medium: ?ThumbnailLocation = null,
    thumbnail: ?ThumbnailLocation = null,
    sensor_dims: ?PhysicalDims = null,
    orientation: Orientation = .normal,

    /// Returns true when any embedded preview or thumbnail bitstream was
    /// located in the container header.
    pub inline fn hasAnyPreview(self: RawHeaderProbe) bool {
        return self.thumbnail != null or
            self.medium != null or
            self.preview != null;
    }

    /// Selects the best placeholder thumbnail candidate (embedded thumbnail or
    /// medium preview) based on `thumb_only` and bounds-checked against
    /// `file_size` and maximum placeholder size.
    pub fn selectPlaceholder(
        self: RawHeaderProbe,
        thumb_only: bool,
        file_size: u64,
    ) ?ThumbnailLocation {
        const candidate = if (thumb_only)
            (self.thumbnail orelse self.medium)
        else
            (self.medium orelse self.thumbnail);
        const loc = candidate orelse return null;
        const max_bytes: u32 = if (thumb_only)
            512 * 1024
        else
            2 * 1024 * 1024;
        return if (loc.isValid(file_size, max_bytes)) loc else null;
    }

    /// Selects an ordered array of candidate preview locations based on
    /// requested maximum dimensions.
    pub fn selectPreviewCandidates(
        self: RawHeaderProbe,
        max_dims: PositiveDimsU32,
    ) [3]?ThumbnailLocation {
        return if (max_dims.w <= 320 and max_dims.h <= 320)
            .{ self.medium, self.preview, self.thumbnail }
        else
            .{ self.preview, self.medium, self.thumbnail };
    }
};

/// Probes an in-memory Camera RAW buffer (Fujifilm RAF or TIFF-based RAW)
/// for preview locations, sensor dimensions, and orientation without
/// performing full decompression.
pub fn probeRawBuffer(
    raw_bytes: []const u8,
    mime_type: []const u8,
) RawHeaderProbe {
    if (isFujiRafHeader(raw_bytes, mime_type)) {
        var res = RawHeaderProbe{
            .preview = extractFujiRafPreviewLocation(raw_bytes),
        };
        if (extractFujiRafMetadataLocation(raw_bytes)) |mloc| {
            if (mloc.sliceInBounds(raw_bytes)) |m_slice| {
                res.sensor_dims = parseFujiRafDimensions(m_slice);
            }
        }
        if (res.preview) |ploc| {
            const maybe_p_slice: ?[]const u8 =
                if (ploc.sliceInBounds(raw_bytes)) |s|
                    s
                else if (ploc.file_offset < raw_bytes.len)
                    raw_bytes[@intCast(ploc.file_offset)..]
                else
                    null;
            if (maybe_p_slice) |p_slice| {
                res.orientation = parseExifOrientation(p_slice) orelse .normal;
                if (extractJpegThumbnailLocation(p_slice)) |j_thumb| {
                    res.thumbnail = .{
                        .file_offset = ploc.file_offset +| j_thumb.file_offset,
                        .length = j_thumb.length,
                    };
                }
                if (res.sensor_dims == null) {
                    res.sensor_dims = readJpegDimensions(p_slice);
                }
            }
        }
        return res;
    }

    const raw_cands = extractTiffRawPreviews(raw_bytes);
    var sensor_dims = parseExifDimensions(raw_bytes);
    if (sensor_dims == null) {
        sensor_dims = parseImageDimensions(raw_bytes, mime_type);
    }
    return .{
        .preview = raw_cands.preview,
        .medium = raw_cands.medium,
        .thumbnail = raw_cands.thumbnail,
        .sensor_dims = sensor_dims,
        .orientation = parseExifOrientation(raw_bytes) orelse .normal,
    };
}

fn probeFujiRafFileHeader(
    io: std.Io,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
) RawHeaderProbe {
    var res = RawHeaderProbe{
        .preview = extractFujiRafPreviewLocation(header_slice),
    };
    const header_n = header_slice.len;
    if (extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
        if (meta_loc.sliceInBounds(header_slice)) |m_slice| {
            res.sensor_dims = parseFujiRafDimensions(m_slice);
        } else if (meta_loc.length > 0 and meta_loc.length <= 64 * 1024) {
            const actual_size = if (file_size > 0)
                file_size
            else
                (file.length(io) catch 0);
            if (actual_size == 0 or
                meta_loc.file_offset +| meta_loc.length <= actual_size)
            {
                var m_buf: [64 * 1024]u8 = undefined;
                const read_target: usize = @intCast(
                    @min(meta_loc.length, m_buf.len),
                );
                var m_slices = [_][]u8{m_buf[0..read_target]};
                const mn = file.readPositional(
                    io,
                    &m_slices,
                    meta_loc.file_offset,
                ) catch 0;
                if (mn >= 4) {
                    res.sensor_dims = parseFujiRafDimensions(m_buf[0..mn]);
                }
            }
        }
    }
    if (res.preview) |prev_loc| {
        if (prev_loc.file_offset +| 4 * 1024 <= header_n) {
            const p_slice =
                header_slice[@intCast(prev_loc.file_offset)..header_n];
            res.orientation = parseExifOrientation(p_slice) orelse .normal;
            if (extractJpegThumbnailLocation(p_slice)) |j_thumb| {
                res.thumbnail = .{
                    .file_offset = prev_loc.file_offset +| j_thumb.file_offset,
                    .length = j_thumb.length,
                };
            }
            if (res.sensor_dims == null) {
                res.sensor_dims = readJpegDimensions(p_slice);
            }
        } else {
            var p_hdr: [8 * 1024]u8 = undefined;
            var p_slices = [_][]u8{&p_hdr};
            const pn = file.readPositional(
                io,
                &p_slices,
                prev_loc.file_offset,
            ) catch 0;
            if (pn > 0) {
                const p_slice = p_hdr[0..pn];
                res.orientation = parseExifOrientation(p_slice) orelse .normal;
                if (extractJpegThumbnailLocation(p_slice)) |j_thumb| {
                    res.thumbnail = .{
                        .file_offset = prev_loc.file_offset +|
                            j_thumb.file_offset,
                        .length = j_thumb.length,
                    };
                }
                if (res.sensor_dims == null) {
                    res.sensor_dims = readJpegDimensions(p_slice);
                }
            }
        }
    }
    return res;
}

fn probeTiffRawFileHeader(
    io: std.Io,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
    mime_type: []const u8,
) RawHeaderProbe {
    var tail_buf: [16 * 1024]u8 = undefined;
    const actual_size: u64 = if (file_size > 0)
        file_size
    else if (probeTiffIfd0Offset(header_slice)) |ifd0_off|
        (if (ifd0_off >= header_slice.len) file.length(io) catch 0 else 0)
    else
        0;
    const tiff_source = readTiffSource(
        io,
        file,
        actual_size,
        header_slice,
        &tail_buf,
    );
    const raw_cands = extractTiffRawPreviewsFromSource(tiff_source);
    var sensor_dims = parseExifDimensionsFromSource(tiff_source);
    if (sensor_dims == null) {
        sensor_dims = parseImageDimensions(header_slice, mime_type);
    }
    const orientation = parseExifOrientationFromSource(tiff_source) orelse
        .normal;
    return .{
        .preview = raw_cands.preview,
        .medium = raw_cands.medium,
        .thumbnail = raw_cands.thumbnail,
        .sensor_dims = sensor_dims,
        .orientation = orientation,
    };
}

/// Probes a Camera RAW file header via `io` and `file`, streaming tail
/// IFD / metadata segments as needed without loading the full file into memory.
pub fn probeRawFileHeader(
    io: std.Io,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
    mime_type: []const u8,
) RawHeaderProbe {
    if (isFujiRafHeader(header_slice, mime_type)) {
        return probeFujiRafFileHeader(io, file, file_size, header_slice);
    }
    return probeTiffRawFileHeader(
        io,
        file,
        file_size,
        header_slice,
        mime_type,
    );
}

/// Synchronously probes container headers within an uncompressed ZIP/CBZ
/// entry for dimensions, EXIF rotation, and embedded thumbnail presence.
pub fn probeStoredZipHeaderMetadata(
    io: std.Io,
    archive_path: []const u8,
    entry_name: []const u8,
    file_offset: u64,
    is_raw_ext: bool,
) ?ProbedImageMetadata {
    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        archive_path,
        .{},
    ) catch |err| {
        std.log.warn(
            "probeStoredZipHeaderMetadata: openFile failed for " ++
                "archive '{s}': {any}",
            .{ archive_path, err },
        );
        return null;
    };
    defer file.close(io);

    var header_buf: [64 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(
        io,
        &slices,
        file_offset,
    ) catch |err| {
        std.log.warn(
            "probeStoredZipHeaderMetadata: readPositional failed for " ++
                "'{s}': {any}",
            .{ archive_path, err },
        );
        return null;
    };
    if (n == 0) return null;

    const image_slice = skipZipLocalFileHeader(header_buf[0..n]) orelse
        return null;

    const mime_type = detectMimeType(image_slice, entry_name);
    const dims = parseImageDimensions(image_slice, mime_type) orelse
        return null;
    const rot = parseExifOrientation(image_slice) orelse .normal;
    const is_raw = is_raw_ext or
        std.mem.startsWith(u8, mime_type, "image/x-");

    var has_thumb = false;
    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
        if (extractJpegThumbnailLocation(image_slice)) |_| {
            has_thumb = true;
        }
    }

    return ProbedImageMetadata{
        .dims = dims,
        .orientation = rot,
        .raw_metadata = if (is_raw)
            RawMetadata.init(dims.w, dims.h)
        else
            .none,
        .has_embedded_thumbnail = has_thumb,
    };
}

/// Synchronously probes container headers for image dimensions, EXIF rotation,
/// and embedded thumbnail presence in < 0.1ms before spawning background decode
/// workers, eliminating Frame-1 layout jumps and UI flicker.
pub fn probeFileHeaderMetadata(
    io: std.Io,
    path: []const u8,
    is_raw_ext: bool,
) ?ProbedImageMetadata {
    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        path,
        .{},
    ) catch |err| {
        std.log.warn(
            "probeFileHeaderMetadata: openFile failed for '{s}': {any}",
            .{ path, err },
        );
        return null;
    };
    defer file.close(io);

    var header_buf: [256 * 1024]u8 = undefined;
    const target_read = if (is_raw_ext) header_buf.len else 128 * 1024;
    var slices = [_][]u8{header_buf[0..target_read]};
    const n = file.readPositional(io, &slices, 0) catch |err| {
        std.log.warn(
            "probeFileHeaderMetadata: readPositional failed for '{s}': " ++
                "{any}",
            .{ path, err },
        );
        return null;
    };
    if (n == 0) return null;

    const mime_type = detectMimeType(header_buf[0..n], path);
    var dims: ?PhysicalDims = null;
    var rot: Orientation = .normal;
    var has_thumb = false;

    const is_raw = is_raw_ext or
        isFujiRafHeader(header_buf[0..n], mime_type) or
        std.mem.startsWith(u8, mime_type, "image/x-");

    if (is_raw) {
        const raw_probe = probeRawFileHeader(
            io,
            &file,
            0,
            header_buf[0..n],
            mime_type,
        );
        dims = raw_probe.sensor_dims orelse
            parseImageDimensions(header_buf[0..n], mime_type);
        rot = raw_probe.orientation;
        has_thumb = raw_probe.hasAnyPreview();
    } else if (std.mem.eql(u8, mime_type, "image/jpeg")) {
        dims = parseImageDimensions(header_buf[0..n], mime_type);
        rot = parseExifOrientation(header_buf[0..n]) orelse
            .normal;
        if (extractJpegThumbnailLocation(header_buf[0..n])) |_| {
            has_thumb = true;
        }
    } else {
        dims = parseImageDimensions(header_buf[0..n], mime_type);
        rot = parseExifOrientation(header_buf[0..n]) orelse
            .normal;
    }

    const final_dims = dims orelse return null;

    return ProbedImageMetadata{
        .dims = final_dims,
        .orientation = rot,
        .raw_metadata = if (is_raw)
            RawMetadata.init(final_dims.w, final_dims.h)
        else
            .none,
        .has_embedded_thumbnail = has_thumb,
    };
}

/// Probes companion JPEG header (first 64KB) for visible photograph
/// dimensions, avoiding raw optical black calibration borders, falling
/// back to probing the RAW file directly on error.
pub fn probeCompanionJpegHeaderMetadata(
    io: std.Io,
    jpeg_path: []const u8,
    raw_path: []const u8,
    is_raw_ext: bool,
) ?ProbedImageMetadata {
    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        jpeg_path,
        .{},
    ) catch |err| {
        std.log.warn(
            "probeCompanionJpegHeaderMetadata: openFile failed for pair " ++
                "JPEG '{s}': {any}",
            .{ jpeg_path, err },
        );
        return probeFileHeaderMetadata(io, raw_path, is_raw_ext);
    };
    defer file.close(io);

    var header_buf: [64 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(io, &slices, 0) catch |err| {
        std.log.warn(
            "probeCompanionJpegHeaderMetadata: readPositional failed " ++
                "for '{s}': {any}",
            .{ jpeg_path, err },
        );
        return probeFileHeaderMetadata(io, raw_path, is_raw_ext);
    };
    if (n < 4) {
        return probeFileHeaderMetadata(io, raw_path, is_raw_ext);
    }

    const rot = parseExifOrientation(header_buf[0..n]) orelse .normal;
    const dims = parseImageDimensions(header_buf[0..n], "image/jpeg") orelse {
        return probeFileHeaderMetadata(io, raw_path, is_raw_ext);
    };

    return ProbedImageMetadata{
        .dims = dims,
        .orientation = rot,
        .raw_metadata = RawMetadata.init(dims.w, dims.h),
        .has_embedded_thumbnail = true,
    };
}

/// Builds a synthetic Sony-like SubIFD ARW/TIFF container in memory for
/// testing. IFD0 defines image dimensions and orientation, pointing to SubIFD
/// at offset 60, which contains an embedded preview JPEG at offset 100.
pub fn buildSyntheticSubIfdArwAlloc(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    orientation_tiff: u16,
    preview_jpeg: []const u8,
) ![]u8 {
    const total_len = 100 + preview_jpeg.len;
    const tiff_buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    // TIFF Header
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 (num = 4)
    std.mem.writeInt(u16, tiff_buf[8..10], 4, .little);
    var off: usize = 10;
    // 1. 0x0100 (ImageWidth)
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], width, .little);
    off += 12;

    // 2. 0x0101 (ImageLength)
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], height, .little);
    off += 12;

    // 3. 0x0112 (Orientation)
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u16,
        tiff_buf[off + 8 ..][0..2],
        orientation_tiff,
        .little,
    );
    off += 12;

    // 4. 0x014A (SubIFD) pointing to offset 60
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x014A, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 60, .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little); // next IFD = 0

    // SubIFD at 60 (num = 2)
    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    // 1. 0x0201 (JPEGInterchangeFormat) pointing to 100
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 100, .little);
    off += 12;

    // 2. 0x0202 (JPEGInterchangeFormatLength) = preview_jpeg.len
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(preview_jpeg.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    // Copy JPEG at 100
    @memcpy(tiff_buf[100 .. 100 + preview_jpeg.len], preview_jpeg);
    return tiff_buf;
}

/// Builds a synthetic Fujifilm RAF container in memory for testing.
/// Header defines preview JPEG at offset 200 and metadata block at offset 120.
pub fn buildSyntheticFujiRafAlloc(
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    preview_jpeg: []const u8,
) ![]u8 {
    const total_len = 200 + preview_jpeg.len;
    const raf_buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(raf_buf);
    @memset(raf_buf, 0);

    @memcpy(raf_buf[0..8], "FUJIFILM");
    std.mem.writeInt(u32, raf_buf[84..88], 200, .big);
    std.mem.writeInt(u32, raf_buf[88..92], @intCast(preview_jpeg.len), .big);
    std.mem.writeInt(u32, raf_buf[92..96], 120, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 12, .big);

    // Metadata block at 120:
    std.mem.writeInt(u32, raf_buf[120..124], 1, .big);
    std.mem.writeInt(u16, raf_buf[124..126], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[126..128], 4, .big);
    std.mem.writeInt(u16, raf_buf[128..130], height, .big);
    std.mem.writeInt(u16, raf_buf[130..132], width, .big);

    // Copy preview JPEG at 200
    @memcpy(raf_buf[200 .. 200 + preview_jpeg.len], preview_jpeg);
    return raf_buf;
}

/// Builds a synthetic 3-tier Sony ARW container in memory for testing:
/// IFD0 points to medium preview, IFD1 points to smallest thumbnail,
/// and IFD2 points to full preview and sets visible dimensions.
pub fn buildSynthetic3TierArwAlloc(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    thumb_jpeg: []const u8,
    med_jpeg: []const u8,
    prev_jpeg: []const u8,
) ![]u8 {
    const header_len: usize = 256;
    const thumb_off: usize = header_len;
    const med_off: usize = thumb_off + thumb_jpeg.len;
    const prev_off: usize = med_off + med_jpeg.len;
    const total_len: usize = prev_off + prev_jpeg.len;

    const tiff_buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    // Little-endian TIFF header, IFD0 at offset 8
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 at 8: 2 entries (medium preview) -> next IFD1 at 60
    var off: usize = 8;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(med_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(med_jpeg.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 60, .little);

    // IFD1 at 60: 2 entries (smallest thumbnail) -> next IFD2 at 110
    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(thumb_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(thumb_jpeg.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 110, .little);

    // IFD2 at 110: 4 entries (largest preview + visible dimensions)
    off = 110;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 4, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], width, .little);
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], height, .little);
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(prev_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(prev_jpeg.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    @memcpy(tiff_buf[thumb_off .. thumb_off + thumb_jpeg.len], thumb_jpeg);
    @memcpy(tiff_buf[med_off .. med_off + med_jpeg.len], med_jpeg);
    @memcpy(tiff_buf[prev_off .. prev_off + prev_jpeg.len], prev_jpeg);
    return tiff_buf;
}

test "parseExifOrientation" {
    // 1. Invalid JPEG header -> null
    try std.testing.expectEqual(
        @as(?Orientation, null),
        parseExifOrientation("not a jpeg file"),
    );

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
    try std.testing.expectEqual(
        @as(?Orientation, .rotate_90),
        parseExifOrientation(&le_exif),
    );

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
    try std.testing.expectEqual(
        @as(?Orientation, .rotate_270),
        parseExifOrientation(&be_exif),
    );

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
    try std.testing.expectEqual(
        @as(?Orientation, .rotate_180),
        parseExifOrientation(&be_exif_180),
    );
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
        // Orientation tag
        0x12, 0x01,
        0x03, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        // IFD1 offset = 26 (relative to TIFF header start)
        0x1A, 0x00,
        0x00, 0x00,
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
        // Thumb payload at offset 56 in TIFF (68 in full buffer)
        0xFF, 0xD8, 0xFF, 0xD9,
    };

    const loc = extractJpegThumbnailLocation(&exif_data);
    try std.testing.expect(loc != null);
    try std.testing.expectEqual(@as(u64, 68), loc.?.file_offset);
    try std.testing.expectEqual(@as(u32, 4), loc.?.length);
    const off = @as(usize, @intCast(loc.?.file_offset));
    const len = @as(usize, @intCast(loc.?.length));
    try std.testing.expectEqualSlices(
        u8,
        &dummy_jpeg,
        exif_data[off .. off + len],
    );
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
        // Tag 0x0100 = 7728
        0x00, 0x01,
        0x03, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x30, 0x1E,
        0x00, 0x00,
        // Tag 0x0101 = 5152
        0x01, 0x01,
        0x03, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x20, 0x14,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
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
    var tiff_buf: [128]u8 = @splat(0);
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
    try std.testing.expectEqual(
        @as(u64, 1000),
        raw_prevs.preview.?.file_offset,
    );
    try std.testing.expectEqual(@as(u32, 2000000), raw_prevs.preview.?.length);
}

test "Fujifilm RAF header and metadata dimension parsing" {
    var raf_header: [120]u8 = @splat(0);
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
    // record 0: tag_id = 0x0111 (cropped), tag_len = 4,
    // data = [height: 4160, width: 6240]
    var meta_buf: [32]u8 = @splat(0);
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
    // but only provide the first 50 bytes in memory (holding IFD0 with
    // Orientation 8).
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

    // Entry 0: tag 0x0112 (Orientation), type SHORT (3), count 1,
    // value 8 (rotate_270)
    std.mem.writeInt(u16, buf[22..24][0..2], 0x0112, .little);
    std.mem.writeInt(u16, buf[24..26][0..2], 3, .little);
    std.mem.writeInt(u32, buf[26..30][0..4], 1, .little);
    std.mem.writeInt(u16, buf[30..32][0..2], 8, .little); // value 8
    std.mem.writeInt(u16, buf[32..34][0..2], 0, .little);

    // parseExifOrientation must successfully parse tag 0x0112 = 8 (.rotate_270)
    // even though the stated APP1 segment length is 60,000 bytes and
    // the slice is only 50 bytes!
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
    var buf: [256]u8 = @splat(0);
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
    try std.testing.expectEqual(
        @as(u64, 500000),
        raw_cands.preview.?.file_offset,
    );
    try std.testing.expectEqual(@as(u32, 2500000), raw_cands.preview.?.length);
    try std.testing.expect(raw_cands.thumbnail == null);

    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 6000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.h);
}

test "Ricoh GR III DNG MakerNote thumbnail extraction (tag 0xC634)" {
    var buf: [512]u8 = @splat(0);
    // TIFF header
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 1 entry
    std.mem.writeInt(u16, buf[8..10], 1, .little);
    // Entry 0: tag 0xC634 (DNGPrivateData), type 7, val_count = 10000,
    // val_or_off = 30
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
    // 8..52: IFD0 (2 entries: 0x014A SubIFD at 100, 0x0201/0x0202 JPEG
    // at 1000 len 100000, next IFD at 52 -> 150)
    // 100..186: SubIFD0 (6 entries: 0x00FE=0 (Raw), 0x0100=6000,
    // 0x0101=4000, 0x0103=7, 0x0106=6, 0x0111/0x0117 Strip at 50000
    // len 30000000)
    // 190..234: IFD1 (2 entries: 0x0201/0x0202 JPEG at 2000 len 5000
    // (thumb), next IFD at 234 -> 240)
    // 240..278: IFD2 (2 entries: 0x0201/0x0202 JPEG at 3000 len 1000000
    // (full prev), next IFD -> 0)
    var buf: [512]u8 = @splat(0);
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

    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 6000.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.?.h);
}

test "probeTiffIfd0Offset - validation and bounds checks" {
    // 1. Truncated header (< 8 bytes)
    try std.testing.expectEqual(@as(?u32, null), probeTiffIfd0Offset(""));
    try std.testing.expectEqual(
        @as(?u32, null),
        probeTiffIfd0Offset("II\x2A\x00"),
    );
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
    try std.testing.expect(
        src.getSlice(std.math.maxInt(usize) - 2, 10) == null,
    );
}

test "synthetic streaming tail IFD0 - dims, orient, preview extraction" {
    // Construct 8-byte TIFF container header pointing to tail IFD0 at
    // offset 1000
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

    // Tail buffer with 2 IFDs: IFD0 at 1000 points to IFD1 at 1030;
    // IFD1 points back to 1000!
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

    // 2. Exif dimensions must extract 4368x2912 from ExifIFD
    // (ignoring IFD2/IFD3)
    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 4368.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 2912.0), dims.?.h);
}

test "extractTiffRawPreviews - null photometric JPEG strip accepted" {
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

test "parseExifDimensions - handles oversized LONG photometric without panic" {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0);

    // Little-endian TIFF header with IFD0 at offset 8
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);

    // IFD0: 3 entries (ImageWidth, ImageLength, PhotometricInterpretation)
    std.mem.writeInt(u16, buf[8..10], 3, .little);

    // Entry 0: ImageWidth (0x0100), LONG (4), count 1, value 1920
    std.mem.writeInt(u16, buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, buf[12..14], 4, .little);
    std.mem.writeInt(u32, buf[14..18], 1, .little);
    std.mem.writeInt(u32, buf[18..22], 1920, .little);

    // Entry 1: ImageLength (0x0101), LONG (4), count 1, value 1080
    std.mem.writeInt(u16, buf[22..24], 0x0101, .little);
    std.mem.writeInt(u16, buf[24..26], 4, .little);
    std.mem.writeInt(u32, buf[26..30], 1, .little);
    std.mem.writeInt(u32, buf[30..34], 1080, .little);

    // Entry 2: Photometric (0x0106), LONG (4), count 1, value > u16
    std.mem.writeInt(u16, buf[34..36], 0x0106, .little);
    std.mem.writeInt(u16, buf[36..38], 4, .little);
    std.mem.writeInt(u32, buf[38..42], 1, .little);
    std.mem.writeInt(u32, buf[42..46], 0x0001_0002, .little);

    const dims = parseExifDimensions(&buf);
    try std.testing.expect(dims != null);
    try std.testing.expectEqual(@as(f32, 1920.0), dims.?.w);
    try std.testing.expectEqual(@as(f32, 1080.0), dims.?.h);
}

test "Orientation.fromTiff and branchless math" {
    // Tag 1 (normal) and 2 (flip horizontal) -> normal (0°)
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(1));
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(2));
    try std.testing.expectEqual(
        @as(f32, 0.0),
        Orientation.normal.toDegrees(),
    );
    try std.testing.expect(!Orientation.normal.isDimensionSwapped());

    // Tag 6 (rotate 90 CW) and 7 (transverse) -> rotate_90 (90°)
    try std.testing.expectEqual(
        Orientation.rotate_90,
        Orientation.fromTiff(6),
    );
    try std.testing.expectEqual(
        Orientation.rotate_90,
        Orientation.fromTiff(7),
    );
    try std.testing.expectEqual(
        @as(f32, 90.0),
        Orientation.rotate_90.toDegrees(),
    );
    try std.testing.expect(Orientation.rotate_90.isDimensionSwapped());

    // Tag 3 (rotate 180) and 4 (flip vertical) -> rotate_180 (180°)
    try std.testing.expectEqual(
        Orientation.rotate_180,
        Orientation.fromTiff(3),
    );
    try std.testing.expectEqual(
        Orientation.rotate_180,
        Orientation.fromTiff(4),
    );
    try std.testing.expectEqual(
        @as(f32, 180.0),
        Orientation.rotate_180.toDegrees(),
    );
    try std.testing.expect(!Orientation.rotate_180.isDimensionSwapped());

    // Tag 8 (rotate 270 CW) and 5 (transpose) -> rotate_270 (270°)
    try std.testing.expectEqual(
        Orientation.rotate_270,
        Orientation.fromTiff(8),
    );
    try std.testing.expectEqual(
        Orientation.rotate_270,
        Orientation.fromTiff(5),
    );
    try std.testing.expectEqual(
        @as(f32, 270.0),
        Orientation.rotate_270.toDegrees(),
    );
    try std.testing.expect(Orientation.rotate_270.isDimensionSwapped());

    // Out of range / unknown tag values default to normal (0°)
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(0));
    try std.testing.expectEqual(
        Orientation.normal,
        Orientation.fromTiff(99),
    );
}

test "parseImageDimensions" {
    // PNG test header
    const png_header = [_]u8{
        0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, // chunk length 13
        'I', 'H', 'D', 'R', // chunk type
        0x00, 0x00, 0x03, 0x20, // width 800
        0x00, 0x00, 0x02, 0x58, // height 600
        // bit depth, color type, compression, filter, interlace
        0x08, 0x02, 0x00, 0x00,
        0x00,
    };
    const png_dims = parseImageDimensions(&png_header, "image/png");
    try std.testing.expect(png_dims != null);
    try std.testing.expectEqual(@as(f32, 800.0), png_dims.?.w);
    try std.testing.expectEqual(@as(f32, 600.0), png_dims.?.h);

    // GIF test header
    const gif_header = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x40, 0x01, // width 320
        0xF0, 0x00, // height 240
    };
    const gif_dims = parseImageDimensions(&gif_header, "image/gif");
    try std.testing.expect(gif_dims != null);
    try std.testing.expectEqual(@as(f32, 320.0), gif_dims.?.w);
    try std.testing.expectEqual(@as(f32, 240.0), gif_dims.?.h);

    // WebP VP8X test header
    const webp_vp8x_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x16, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  'X',
        0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, // flags
        0x7F, 0x07, 0x00, // canvas w - 1 (1919 -> 1920)
        0x37, 0x04, 0x00, // canvas h - 1 (1079 -> 1080)
    };
    const vp8x_dims = parseImageDimensions(&webp_vp8x_header, "image/webp");
    try std.testing.expect(vp8x_dims != null);
    try std.testing.expectEqual(@as(f32, 1920.0), vp8x_dims.?.w);
    try std.testing.expectEqual(@as(f32, 1080.0), vp8x_dims.?.h);

    // WebP VP8L test header (25 bytes minimal)
    const webp_vp8l_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x11, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  'L',
        0x05, 0x00, 0x00, 0x00,
        0x2F, // 1-byte signature
        0xE7, 0xC3, 0x7C, 0x00, // w: 1000, h: 500
    };
    const vp8l_dims = parseImageDimensions(&webp_vp8l_header, "image/webp");
    try std.testing.expect(vp8l_dims != null);
    try std.testing.expectEqual(@as(f32, 1000.0), vp8l_dims.?.w);
    try std.testing.expectEqual(@as(f32, 500.0), vp8l_dims.?.h);

    // WebP VP8 lossy test header
    const webp_vp8_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x16, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  ' ',
        0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, // frame tag
        0x9D, 0x01, 0x2A, // start code
        0x80, 0x02, // w: 640
        0xE0, 0x01, // h: 480
    };
    const vp8_dims = parseImageDimensions(&webp_vp8_header, "image/webp");
    try std.testing.expect(vp8_dims != null);
    try std.testing.expectEqual(@as(f32, 640.0), vp8_dims.?.w);
    try std.testing.expectEqual(@as(f32, 480.0), vp8_dims.?.h);

    // BMP test header (top-down with negative height)
    const bmp_header = [_]u8{
        'B', 'M',
        0x36, 0x00, 0x0C, 0x00, // file size
        0x00, 0x00, 0x00, 0x00, // reserved
        0x36, 0x00, 0x00, 0x00, // offset to pixels
        40, 0x00, 0x00, 0x00, // DIB size (40)
        0x00, 0x04, 0x00, 0x00, // w: 1024
        0x00, 0xFD, 0xFF, 0xFF, // h: -768 (top-down)
    };
    const bmp_dims = parseImageDimensions(&bmp_header, "image/bmp");
    try std.testing.expect(bmp_dims != null);
    try std.testing.expectEqual(@as(f32, 1024.0), bmp_dims.?.w);
    try std.testing.expectEqual(@as(f32, 768.0), bmp_dims.?.h);
}

test "parseImageDimensions - rejects extreme Fuji RAF offsets" {
    var raf_hdr: [128]u8 = @splat(0);
    @memcpy(raf_hdr[0..16], "FUJIFILMCCD-RAW ");
    // Preview JPEG offset = 0xFFFF_FFF0, length = 0x100
    std.mem.writeInt(u32, raf_hdr[84..88], 0xFFFF_FFF0, .big);
    std.mem.writeInt(u32, raf_hdr[88..92], 0x0000_0100, .big);
    // Metadata offset = 0xFFFF_FFF0, length = 0x100
    std.mem.writeInt(u32, raf_hdr[92..96], 0xFFFF_FFF0, .big);
    std.mem.writeInt(u32, raf_hdr[96..100], 0x0000_0100, .big);

    try std.testing.expect(
        parseImageDimensions(&raf_hdr, "image/x-fuji-raf") == null,
    );

    // Offset = 0 with length > header.len must also be rejected safely
    std.mem.writeInt(u32, raf_hdr[84..88], 0, .big);
    std.mem.writeInt(u32, raf_hdr[88..92], 1000, .big);
    std.mem.writeInt(u32, raf_hdr[92..96], 0, .big);
    std.mem.writeInt(u32, raf_hdr[96..100], 1000, .big);

    try std.testing.expect(
        parseImageDimensions(&raf_hdr, "image/x-fuji-raf") == null,
    );
    try std.testing.expect(
        parseImageDimensions(raf_hdr[0..16], "image/x-fuji-raf") == null,
    );
}

test "detectMimeType - magic bytes and extension fallback" {
    const png_hdr = [_]u8{
        0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A,
    };
    try std.testing.expectEqualStrings(
        "image/png",
        detectMimeType(&png_hdr, "foo.bin"),
    );

    const jpg_hdr = [_]u8{ 0xFF, 0xD8, 0xFF };
    try std.testing.expectEqualStrings(
        "image/jpeg",
        detectMimeType(&jpg_hdr, "photo.dat"),
    );

    const gif_hdr = "GIF89a...";
    try std.testing.expectEqualStrings(
        "image/gif",
        detectMimeType(gif_hdr, "anim.bin"),
    );

    const bmp_hdr = "BM\x00\x00";
    try std.testing.expectEqualStrings(
        "image/bmp",
        detectMimeType(bmp_hdr, "art.bin"),
    );

    const webp_hdr = "RIFF\x00\x00\x00\x00WEBPVP8 ";
    try std.testing.expectEqualStrings(
        "image/webp",
        detectMimeType(webp_hdr, "img.bin"),
    );

    const fuji_hdr = "FUJIFILM\x00\x00";
    try std.testing.expectEqualStrings(
        "image/x-fuji-raf",
        detectMimeType(fuji_hdr, "raw.bin"),
    );

    // Fallback by extension
    const empty_hdr = [_]u8{};
    try std.testing.expectEqualStrings(
        "image/png",
        detectMimeType(&empty_hdr, "pic.png"),
    );
    try std.testing.expectEqualStrings(
        "image/jpeg",
        detectMimeType(&empty_hdr, "pic.jpg"),
    );
    try std.testing.expectEqualStrings(
        "image/x-sony-arw",
        detectMimeType(&empty_hdr, "pic.arw"),
    );
    try std.testing.expectEqualStrings(
        "unknown",
        detectMimeType(&empty_hdr, "pic.xyz"),
    );
}

test "skipZipLocalFileHeader - valid, pass-through, truncated, empty" {
    // 1. Valid stored ZIP local file header with filename and extra field
    var zip_buf: [64]u8 = @splat(0);
    @memcpy(zip_buf[0..4], &std.zip.local_file_header_sig);
    const fname_len: u16 = 8;
    const extra_len: u16 = 4;
    std.mem.writeInt(u16, zip_buf[26..28], fname_len, .little);
    std.mem.writeInt(u16, zip_buf[28..30], extra_len, .little);
    const payload_start = @sizeOf(std.zip.LocalFileHeader) +
        fname_len + extra_len;
    @memcpy(zip_buf[payload_start .. payload_start + 5], "IMAGE");

    const skipped = skipZipLocalFileHeader(zip_buf[0 .. payload_start + 5]);
    try std.testing.expect(skipped != null);
    try std.testing.expectEqualStrings("IMAGE", skipped.?);

    // 2. Non-ZIP raw payload pass-through
    const raw_jpg = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01";
    const pass_thru = skipZipLocalFileHeader(raw_jpg);
    try std.testing.expect(pass_thru != null);
    try std.testing.expectEqualStrings(raw_jpg, pass_thru.?);

    // 3. Truncated local file header (payload smaller than header + lengths)
    const truncated_hdr = zip_buf[0..payload_start];
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        skipZipLocalFileHeader(truncated_hdr),
    );

    // 4. Empty buffer
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        skipZipLocalFileHeader(""),
    );
}

test "isFujiRafHeader and ThumbnailLocation.sliceInBounds" {
    try std.testing.expect(isFujiRafHeader("test", "image/x-fuji-raf"));
    try std.testing.expect(isFujiRafHeader("FUJIFILM\x00\x00", "unknown"));
    try std.testing.expect(!isFujiRafHeader(
        "RIFF\x00\x00\x00\x00WEBP",
        "image/webp",
    ));
    try std.testing.expect(!isFujiRafHeader("FUJI", "unknown"));

    const buf = "0123456789abcdefghij";
    const valid_loc = ThumbnailLocation{ .file_offset = 5, .length = 4 };
    try std.testing.expectEqualStrings("5678", valid_loc.sliceInBounds(buf).?);

    const empty_loc = ThumbnailLocation{ .file_offset = 5, .length = 0 };
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        empty_loc.sliceInBounds(buf),
    );

    const oob_loc = ThumbnailLocation{ .file_offset = 18, .length = 5 };
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        oob_loc.sliceInBounds(buf),
    );

    const overflow_loc = ThumbnailLocation{
        .file_offset = std.math.maxInt(u64) - 2,
        .length = 10,
    };
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        overflow_loc.sliceInBounds(buf),
    );
}

test "probeRawBuffer - Fuji RAF and TIFF RAW containers" {
    // 1. Fuji RAF buffer in memory
    var raf_buf: [256]u8 = @splat(0);
    @memcpy(raf_buf[0..8], "FUJIFILM");
    // Preview at offset 128, length 64
    std.mem.writeInt(u32, raf_buf[84..88], 128, .big);
    std.mem.writeInt(u32, raf_buf[88..92], 64, .big);
    // Metadata at offset 64, length 24
    std.mem.writeInt(u32, raf_buf[92..96], 64, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 24, .big);
    // Metadata: num_records = 1, tag 0x0111, len = 4, [h: 4000, w: 6000]
    std.mem.writeInt(u32, raf_buf[64..68], 1, .big);
    std.mem.writeInt(u16, raf_buf[68..70], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[70..72], 4, .big);
    std.mem.writeInt(u16, raf_buf[72..74], 4000, .big);
    std.mem.writeInt(u16, raf_buf[74..76], 6000, .big);
    // Preview at 128: valid SOI and SOF0 marker
    raf_buf[128] = 0xFF;
    raf_buf[129] = 0xD8;
    raf_buf[130] = 0xFF;
    raf_buf[131] = 0xC0; // SOF0
    raf_buf[132] = 0x00; // seg len 11
    raf_buf[133] = 0x0B;
    raf_buf[134] = 0x08; // precision
    std.mem.writeInt(u16, raf_buf[135..137], 200, .big); // h
    std.mem.writeInt(u16, raf_buf[137..139], 300, .big); // w

    const raf_res = probeRawBuffer(&raf_buf, "image/x-fuji-raf");
    try std.testing.expect(raf_res.hasAnyPreview());
    try std.testing.expectEqual(@as(u64, 128), raf_res.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 64), raf_res.preview.?.length);
    try std.testing.expectEqual(@as(f32, 6000.0), raf_res.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), raf_res.sensor_dims.?.h);

    // 2. TIFF RAW buffer in memory (Sony ARW / TIFF layout)
    var tiff_buf: [128]u8 = @splat(0);
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    std.mem.writeInt(u16, tiff_buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);
    // IFD0 at 8: 3 entries
    std.mem.writeInt(u16, tiff_buf[8..10], 3, .little);
    // Entry 0: 0x0100 (ImageWidth) = 7952
    std.mem.writeInt(u16, tiff_buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[12..14], 4, .little);
    std.mem.writeInt(u32, tiff_buf[14..18], 1, .little);
    std.mem.writeInt(u32, tiff_buf[18..22], 7952, .little);
    // Entry 1: 0x0101 (ImageLength) = 5304
    std.mem.writeInt(u16, tiff_buf[22..24], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[24..26], 4, .little);
    std.mem.writeInt(u32, tiff_buf[26..30], 1, .little);
    std.mem.writeInt(u32, tiff_buf[30..34], 5304, .little);
    // Entry 2: 0x0112 (Orientation) = 6 (rotate_90)
    std.mem.writeInt(u16, tiff_buf[34..36], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[36..38], 3, .little);
    std.mem.writeInt(u32, tiff_buf[38..42], 1, .little);
    std.mem.writeInt(u16, tiff_buf[42..44], 6, .little);
    // Next IFD = 50
    std.mem.writeInt(u32, tiff_buf[46..50], 50, .little);
    // IFD1 at 50: 2 entries (JPEG thumbnail)
    std.mem.writeInt(u16, tiff_buf[50..52], 2, .little);
    std.mem.writeInt(u16, tiff_buf[52..54], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[54..56], 4, .little);
    std.mem.writeInt(u32, tiff_buf[56..60], 1, .little);
    std.mem.writeInt(u32, tiff_buf[60..64], 1000, .little);
    std.mem.writeInt(u16, tiff_buf[64..66], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[66..68], 4, .little);
    std.mem.writeInt(u32, tiff_buf[68..72], 1, .little);
    std.mem.writeInt(u32, tiff_buf[72..76], 120000, .little);

    const tiff_res = probeRawBuffer(&tiff_buf, "image/x-sony-arw");
    try std.testing.expect(tiff_res.hasAnyPreview());
    try std.testing.expectEqual(Orientation.rotate_90, tiff_res.orientation);
    try std.testing.expectEqual(@as(f32, 7952.0), tiff_res.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 5304.0), tiff_res.sensor_dims.?.h);
    try std.testing.expectEqual(@as(u64, 1000), tiff_res.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 120000), tiff_res.preview.?.length);
}

test "probeRawFileHeader - Fuji RAF and TIFF RAW file streaming" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. Fuji RAF file
    var raf_buf: [256]u8 = @splat(0);
    @memcpy(raf_buf[0..8], "FUJIFILM");
    std.mem.writeInt(u32, raf_buf[84..88], 128, .big);
    std.mem.writeInt(u32, raf_buf[88..92], 64, .big);
    std.mem.writeInt(u32, raf_buf[92..96], 64, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 24, .big);
    std.mem.writeInt(u32, raf_buf[64..68], 1, .big);
    std.mem.writeInt(u16, raf_buf[68..70], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[70..72], 4, .big);
    std.mem.writeInt(u16, raf_buf[72..74], 4000, .big);
    std.mem.writeInt(u16, raf_buf[74..76], 6000, .big);

    var raf_file = try tmp.dir.createFile(
        io,
        "sample.raf",
        .{ .read = true },
    );
    defer raf_file.close(io);
    var r_slices = [_][]const u8{&raf_buf};
    _ = try raf_file.writePositional(io, &r_slices, 0);

    const raf_res = probeRawFileHeader(
        io,
        &raf_file,
        raf_buf.len,
        raf_buf[0..100],
        "image/x-fuji-raf",
    );
    try std.testing.expect(raf_res.hasAnyPreview());
    try std.testing.expectEqual(@as(u64, 128), raf_res.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 64), raf_res.preview.?.length);
    try std.testing.expectEqual(@as(f32, 6000.0), raf_res.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 4000.0), raf_res.sensor_dims.?.h);

    // 2. TIFF RAW file
    var tiff_buf: [128]u8 = @splat(0);
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    std.mem.writeInt(u16, tiff_buf[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);
    std.mem.writeInt(u16, tiff_buf[8..10], 3, .little);
    std.mem.writeInt(u16, tiff_buf[10..12], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[12..14], 4, .little);
    std.mem.writeInt(u32, tiff_buf[14..18], 1, .little);
    std.mem.writeInt(u32, tiff_buf[18..22], 7952, .little);
    std.mem.writeInt(u16, tiff_buf[22..24], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[24..26], 4, .little);
    std.mem.writeInt(u32, tiff_buf[26..30], 1, .little);
    std.mem.writeInt(u32, tiff_buf[30..34], 5304, .little);
    std.mem.writeInt(u16, tiff_buf[34..36], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[36..38], 3, .little);
    std.mem.writeInt(u32, tiff_buf[38..42], 1, .little);
    std.mem.writeInt(u16, tiff_buf[42..44], 6, .little);
    std.mem.writeInt(u32, tiff_buf[46..50], 50, .little);
    std.mem.writeInt(u16, tiff_buf[50..52], 2, .little);
    std.mem.writeInt(u16, tiff_buf[52..54], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[54..56], 4, .little);
    std.mem.writeInt(u32, tiff_buf[56..60], 1, .little);
    std.mem.writeInt(u32, tiff_buf[60..64], 1000, .little);
    std.mem.writeInt(u16, tiff_buf[64..66], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[66..68], 4, .little);
    std.mem.writeInt(u32, tiff_buf[68..72], 1, .little);
    std.mem.writeInt(u32, tiff_buf[72..76], 120000, .little);

    var tiff_file = try tmp.dir.createFile(
        io,
        "sample.arw",
        .{ .read = true },
    );
    defer tiff_file.close(io);
    var t_slices = [_][]const u8{&tiff_buf};
    _ = try tiff_file.writePositional(io, &t_slices, 0);

    const tiff_res = probeRawFileHeader(
        io,
        &tiff_file,
        tiff_buf.len,
        &tiff_buf,
        "image/x-sony-arw",
    );
    try std.testing.expect(tiff_res.hasAnyPreview());
    try std.testing.expectEqual(Orientation.rotate_90, tiff_res.orientation);
    try std.testing.expectEqual(@as(f32, 7952.0), tiff_res.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 5304.0), tiff_res.sensor_dims.?.h);
    try std.testing.expectEqual(@as(u64, 1000), tiff_res.preview.?.file_offset);
    try std.testing.expectEqual(@as(u32, 120000), tiff_res.preview.?.length);
}

test "RawMetadata tagged union invariants and constructor" {
    // Valid dimensions
    const valid = RawMetadata.init(6000.0, 4000.0);
    try std.testing.expect(valid.isRaw());
    const dims = valid.getSensorDims().?;
    try std.testing.expectEqual(@as(f32, 6000.0), dims.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.h);

    // Invalid zero or negative dimensions return .none
    try std.testing.expectEqual(RawMetadata.none, RawMetadata.init(0.0, 0.0));
    try std.testing.expectEqual(
        RawMetadata.none,
        RawMetadata.init(-100.0, 4000.0),
    );
    try std.testing.expectEqual(
        RawMetadata.none,
        RawMetadata.init(6000.0, 0.0),
    );
    try std.testing.expectEqual(
        RawMetadata.none,
        RawMetadata.init(std.math.nan(f32), 4000.0),
    );
    try std.testing.expectEqual(
        RawMetadata.none,
        RawMetadata.init(std.math.inf(f32), 4000.0),
    );

    // .none variant returns false and null
    const none_meta: RawMetadata = .none;
    try std.testing.expect(!none_meta.isRaw());
    try std.testing.expect(none_meta.getSensorDims() == null);
}

test "probeFileHeaderMetadata - filesystem JPEG" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const meta = probeFileHeaderMetadata(
        io,
        "testfiles/images/000_0_1024x682.jpg",
        false,
    );
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
        try std.testing.expectEqual(Orientation.normal, m.orientation);
    }
}

test "probeFileHeaderMetadata - nonexistent file returns null" {
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        probeFileHeaderMetadata(io, "testfiles/nonexistent.jpg", false),
    );
}

test "probeStoredZipHeaderMetadata and probeCompanionJpegHeaderMetadata" {
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const io = std.Io.Threaded.global_single_threaded.io();

    // Uncompressed entry with valid offset
    const meta = probeStoredZipHeaderMetadata(
        io,
        "testfiles/images/000_0_1024x682.jpg",
        "test.jpg",
        0,
        false,
    );
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
    }

    // Companion JPEG probing
    const comp_meta = probeCompanionJpegHeaderMetadata(
        io,
        "testfiles/images/000_0_1024x682.jpg",
        "testfiles/nonexistent.raw",
        true,
    );
    try std.testing.expect(comp_meta != null);
    if (comp_meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
        try std.testing.expect(m.has_embedded_thumbnail);
        try std.testing.expect(m.raw_metadata.isRaw());
    }

    // Companion JPEG missing fallback
    const fallback = probeCompanionJpegHeaderMetadata(
        io,
        "testfiles/nonexistent.jpg",
        "testfiles/images/000_0_1024x682.jpg",
        false,
    );
    try std.testing.expect(fallback != null);
    if (fallback) |f| {
        try std.testing.expectEqual(@as(f32, 1024.0), f.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), f.dims.h);
    }
}

test "probeFileHeaderMetadata - embedded thumbnail on mock RAF" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const fixture_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        fixture_path,
        .{},
    );
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        fixture_path,
        .{},
    );
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    // Construct mock Fujifilm RAF
    var raf_buf = try allocator.alloc(u8, 200 + jpg_bytes.len);
    defer allocator.free(raf_buf);
    @memset(raf_buf, 0);

    @memcpy(raf_buf[0..8], "FUJIFILM");
    std.mem.writeInt(u32, raf_buf[84..88], 200, .big);
    std.mem.writeInt(u32, raf_buf[88..92], @intCast(jpg_bytes.len), .big);
    std.mem.writeInt(u32, raf_buf[92..96], 120, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 12, .big);

    // Metadata block at 120:
    std.mem.writeInt(u32, raf_buf[120..124], 1, .big);
    std.mem.writeInt(u16, raf_buf[124..126], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[126..128], 4, .big);
    std.mem.writeInt(u16, raf_buf[128..130], 4160, .big);
    std.mem.writeInt(u16, raf_buf[130..132], 6240, .big);

    // Copy preview JPEG at 200
    @memcpy(raf_buf[200 .. 200 + jpg_bytes.len], jpg_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_probe_test.raf", .{});
    var wr_slices = [_][]const u8{raf_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_probe_test.raf",
        .{tmp.sub_path},
    );

    const meta = probeFileHeaderMetadata(io, mock_path, true);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expect(m.has_embedded_thumbnail);
        try std.testing.expectEqual(@as(f32, 6240.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 4160.0), m.dims.h);
        try std.testing.expect(m.raw_metadata.isRaw());
    }
}

test "probeFileHeaderMetadata - non-thumbnail formats return false" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const meta = probeFileHeaderMetadata(
        io,
        "testfiles/golden-screenshots/init.png",
        false,
    );
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expect(!m.has_embedded_thumbnail);
        try std.testing.expect(m.dims.w > 0);
        try std.testing.expect(m.dims.h > 0);
    }
}

test "isRawContainer, isValid, and synthetic RAW builders" {
    // 1. isRawContainer
    try std.testing.expect(isRawContainer("FUJIFILM\x00\x00", "unknown"));
    try std.testing.expect(isRawContainer("", "image/x-sony-arw"));
    try std.testing.expect(!isRawContainer("", "image/jpeg"));
    try std.testing.expect(!isRawContainer("", "image/png"));

    // 2. ThumbnailLocation.isValid
    const loc = ThumbnailLocation{ .file_offset = 100, .length = 200 };
    try std.testing.expect(loc.isValid(300, null));
    try std.testing.expect(loc.isValid(300, 200));
    try std.testing.expect(!loc.isValid(300, 199));
    try std.testing.expect(!loc.isValid(299, null));

    const zero_loc = ThumbnailLocation{ .file_offset = 100, .length = 0 };
    try std.testing.expect(!zero_loc.isValid(500, null));

    const ovf_loc = ThumbnailLocation{
        .file_offset = std.math.maxInt(u64) - 50,
        .length = 100,
    };
    try std.testing.expect(!ovf_loc.isValid(std.math.maxInt(u64), null));

    // 3. extractValidJpegThumbnailLocation
    const exif_head = [_]u8{
        0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x44, 'E',  'x',  'i',  'f',  0x00, 0x00,
        'I',  'I',  0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, 0x01,
        0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x01, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x38, 0x00, 0x00, 0x00, 0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqual(
        @as(?ThumbnailLocation, null),
        extractValidJpegThumbnailLocation(&exif_head, "image/png", 100, null),
    );
    try std.testing.expectEqual(
        @as(?ThumbnailLocation, null),
        extractValidJpegThumbnailLocation(&exif_head, "image/jpeg", 50, null),
    );
    try std.testing.expectEqual(
        @as(?ThumbnailLocation, null),
        extractValidJpegThumbnailLocation(&exif_head, "image/jpeg", 100, 2),
    );
    const valid_jloc = extractValidJpegThumbnailLocation(
        &exif_head,
        "image/jpeg",
        100,
        null,
    );
    try std.testing.expect(valid_jloc != null);
    try std.testing.expectEqual(
        ThumbnailLocation{ .file_offset = 68, .length = 4 },
        valid_jloc.?,
    );

    // 4. RawHeaderProbe.selectPlaceholder
    const probe_both = RawHeaderProbe{
        .thumbnail = .{ .file_offset = 100, .length = 1000 },
        .medium = .{ .file_offset = 2000, .length = 50000 },
    };
    const sel_thumb = probe_both.selectPlaceholder(true, 100_000);
    try std.testing.expectEqual(
        ThumbnailLocation{ .file_offset = 100, .length = 1000 },
        sel_thumb.?,
    );
    const sel_med = probe_both.selectPlaceholder(false, 100_000);
    try std.testing.expectEqual(
        ThumbnailLocation{ .file_offset = 2000, .length = 50000 },
        sel_med.?,
    );

    const big_thumb = RawHeaderProbe{
        .thumbnail = .{ .file_offset = 100, .length = 600 * 1024 },
    };
    try std.testing.expectEqual(
        @as(?ThumbnailLocation, null),
        big_thumb.selectPlaceholder(true, 1024 * 1024),
    );

    // 5. RawHeaderProbe.selectPreviewCandidates
    const p1 = ThumbnailLocation{ .file_offset = 10, .length = 100 };
    const p2 = ThumbnailLocation{ .file_offset = 20, .length = 200 };
    const p3 = ThumbnailLocation{ .file_offset = 30, .length = 300 };
    const probe_3 = RawHeaderProbe{
        .preview = p1,
        .medium = p2,
        .thumbnail = p3,
    };
    const small_cands = probe_3.selectPreviewCandidates(.{
        .w = 200,
        .h = 200,
    });
    try std.testing.expectEqual(p2, small_cands[0].?);
    try std.testing.expectEqual(p1, small_cands[1].?);
    try std.testing.expectEqual(p3, small_cands[2].?);

    const large_cands = probe_3.selectPreviewCandidates(.{
        .w = 800,
        .h = 600,
    });
    try std.testing.expectEqual(p1, large_cands[0].?);
    try std.testing.expectEqual(p2, large_cands[1].?);
    try std.testing.expectEqual(p3, large_cands[2].?);

    // 6. Synthetic RAW container builders
    const alloc = std.testing.allocator;
    const mock_jpeg = "\xFF\xD8\xFF\xD9";

    const arw = try buildSyntheticSubIfdArwAlloc(
        alloc,
        4000,
        3000,
        6,
        mock_jpeg,
    );
    defer alloc.free(arw);
    const arw_probe = probeRawBuffer(arw, "image/x-sony-arw");
    try std.testing.expect(arw_probe.hasAnyPreview());
    try std.testing.expectEqual(Orientation.rotate_90, arw_probe.orientation);
    try std.testing.expect(arw_probe.sensor_dims != null);
    try std.testing.expectEqual(@as(f32, 4000), arw_probe.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 3000), arw_probe.sensor_dims.?.h);

    const raf = try buildSyntheticFujiRafAlloc(
        alloc,
        6000,
        4000,
        mock_jpeg,
    );
    defer alloc.free(raf);
    const raf_probe = probeRawBuffer(raf, "image/x-fuji-raf");
    try std.testing.expect(raf_probe.hasAnyPreview());
    try std.testing.expect(raf_probe.sensor_dims != null);
    try std.testing.expectEqual(@as(f32, 6000), raf_probe.sensor_dims.?.w);
    const mock_thumb = "\xFF\xD8\xFF\xD9" ++ "0123456789";
    const mock_med = "\xFF\xD8\xFF\xD9" ++
        "01234567890123456789012345678901234567890";
    const mock_prev = "\xFF\xD8\xFF\xD9" ++
        "0123456789012345678901234567890123456789012345678901234567890";

    const arw3 = try buildSynthetic3TierArwAlloc(
        alloc,
        8000,
        6000,
        mock_thumb,
        mock_med,
        mock_prev,
    );
    defer alloc.free(arw3);
    const arw3_probe = probeRawBuffer(arw3, "image/x-sony-arw");
    try std.testing.expect(arw3_probe.preview != null);
    try std.testing.expect(arw3_probe.medium != null);
    try std.testing.expect(arw3_probe.thumbnail != null);
    try std.testing.expect(arw3_probe.sensor_dims != null);
    try std.testing.expectEqual(@as(f32, 8000), arw3_probe.sensor_dims.?.w);
    try std.testing.expectEqual(@as(f32, 6000), arw3_probe.sensor_dims.?.h);
}
