const geom = @import("geom");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

const max_colors: usize = 256;
const max_preview_dim: u32 = 4096;
const hist_size: usize = 32 * 32 * 32;
const lut_empty: u16 = 0xFFFF;

/// Compact 16-byte histogram bucket (`u32` sums cannot overflow up to
/// `4096 * 4096 * 255 = 4,278,190,080 < maxInt(u32)`).
const HistEntry = struct {
    count: u32 = 0,
    r_sum: u32 = 0,
    g_sum: u32 = 0,
    b_sum: u32 = 0,
};

const Bucket = struct {
    key: u16,
    count: u32,
    r: u8,
    g: u8,
    b: u8,
};

const ColorBox = struct {
    start: usize,
    end: usize,
    count: u64,
    r_min: u8,
    r_max: u8,
    g_min: u8,
    g_max: u8,
    b_min: u8,
    b_max: u8,

    fn longestAxis(self: ColorBox) u2 {
        const dr = self.r_max - self.r_min;
        const dg = self.g_max - self.g_min;
        const db = self.b_max - self.b_min;
        if (dg >= dr and dg >= db) return 1;
        if (dr >= dg and dr >= db) return 0;
        return 2;
    }

    fn maxRange(self: ColorBox) u8 {
        return @max(
            self.r_max - self.r_min,
            @max(self.g_max - self.g_min, self.b_max - self.b_min),
        );
    }

    fn splitScore(self: ColorBox) u64 {
        if (self.end - self.start <= 1) return 0;
        const range: u64 = self.maxRange();
        if (range == 0) return 0;
        return range * self.count;
    }
};

const Palette = struct {
    r: [max_colors]i16 = @splat(0),
    g: [max_colors]i16 = @splat(0),
    b: [max_colors]i16 = @splat(0),
    len: usize = 0,
};

const BandEntry = packed struct(u32) {
    x: u16,
    color: u8,
    mask: u8,
};

/// 4x4 Bayer ordered dither offsets scaled to [-12..+10] for 256-color
/// palettes, tiled across 8 SIMD lanes per row.
const bayer_rows = [4]@Vector(8, i16){
    .{ -12, 0, -9, 3, -12, 0, -9, 3 },
    .{ 6, -6, 9, -3, 6, -6, 9, -3 },
    .{ -7, 4, -10, 1, -7, 4, -10, 1 },
    .{ 10, -1, 7, -4, 10, -1, 7, -4 },
};

inline fn premultiplyChannel(c: u8, a: u8) u8 {
    return @intCast((@as(u16, c) * @as(u16, a) + 127) / 255);
}

inline fn rgbToKey(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 10) |
        (@as(u16, g >> 3) << 5) |
        @as(u16, b >> 3);
}

const DecLutEntry = struct {
    bytes: [4]u8,
    len: u8,
};

const dec_lut: [1024]DecLutEntry = blk: {
    @setEvalBranchQuota(10000);
    var lut: [1024]DecLutEntry = undefined;
    for (0..1024) |n| {
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        var len: u8 = 0;
        if (n >= 1000) {
            bytes[0] = @intCast('0' + (n / 1000));
            bytes[1] = @intCast('0' + ((n / 100) % 10));
            bytes[2] = @intCast('0' + ((n / 10) % 10));
            bytes[3] = @intCast('0' + (n % 10));
            len = 4;
        } else if (n >= 100) {
            bytes[0] = @intCast('0' + (n / 100));
            bytes[1] = @intCast('0' + ((n / 10) % 10));
            bytes[2] = @intCast('0' + (n % 10));
            len = 3;
        } else if (n >= 10) {
            bytes[0] = @intCast('0' + (n / 10));
            bytes[1] = @intCast('0' + (n % 10));
            len = 2;
        } else {
            bytes[0] = @intCast('0' + n);
            len = 1;
        }
        lut[n] = .{ .bytes = bytes, .len = len };
    }
    break :blk lut;
};

/// Local stack-buffered Sixel byte emitter that coalesces millions of 1–4 byte
/// RLE/header writes into large 16 KiB `writer.writeAll` flushes.
const BandBuf = struct {
    writer: *std.Io.Writer,
    buf: [16384]u8 = undefined,
    len: usize = 0,

    inline fn flush(self: *BandBuf) !void {
        if (self.len > 0) {
            try self.writer.writeAll(self.buf[0..self.len]);
            self.len = 0;
        }
    }

    inline fn ensure(self: *BandBuf, need: usize) !void {
        if (self.len + need > self.buf.len) {
            try self.flush();
        }
    }

    inline fn appendByte(self: *BandBuf, b: u8) !void {
        try self.ensure(1);
        self.buf[self.len] = b;
        self.len += 1;
    }

    inline fn appendSlice(self: *BandBuf, bytes: []const u8) !void {
        if (bytes.len <= self.buf.len) {
            try self.ensure(bytes.len);
            @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
            self.len += bytes.len;
        } else {
            try self.flush();
            try self.writer.writeAll(bytes);
        }
    }

    /// Encodes `val` in ASCII decimal into a fixed 20-byte buffer, returning
    /// the number of bytes written (`1..20`).
    inline fn encodeUint(dst: *[20]u8, val: usize) usize {
        if (val < dec_lut.len) {
            const e = dec_lut[val];
            dst[0..4].* = e.bytes;
            return e.len;
        }
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var n = val;
        while (n > 0) : (n /= 10) {
            i -= 1;
            tmp[i] = @intCast('0' + (n % 10));
        }
        const digits = tmp[i..];
        @memcpy(dst[0..digits.len], digits);
        return digits.len;
    }

    /// Encodes one Sixel RLE run into a fixed 22-byte buffer, returning the
    /// number of bytes written (`0..22`).
    inline fn encodeRleRun(dst: *[22]u8, ch: u8, count: usize) usize {
        if (count == 0) return 0;
        if (count >= 4) {
            dst[0] = '!';
            const n = encodeUint(dst[1..21], count);
            dst[1 + n] = ch;
            return n + 2;
        }
        dst[0..4].* = .{ ch, ch, ch, ch };
        return count;
    }

    inline fn reserve(self: *BandBuf, comptime n: usize) !*[n]u8 {
        comptime std.debug.assert(n <= 16384);
        try self.ensure(n);
        return self.buf[self.len..][0..n];
    }

    inline fn commit(self: *BandBuf, n: usize) void {
        std.debug.assert(self.len + n <= self.buf.len);
        self.len += n;
    }

    inline fn appendUint(self: *BandBuf, val: usize) !void {
        const dst = try self.reserve(20);
        self.commit(encodeUint(dst, val));
    }
};

/// Premultiplies RGBA32 onto black and populates the 5-bit RGB histogram
/// using 8-pixel SIMD batches with a fast opaque path.
fn buildHistogramAndRgb(
    rgba_pixels: []const u8,
    pitch: usize,
    w: usize,
    h: usize,
    hist: []HistEntry,
    rgb_buf: []u8,
) void {
    const Vec8u8 = @Vector(8, u8);
    const Vec8u16 = @Vector(8, u16);
    const opaque_mask: Vec8u8 = @splat(255);
    const round_127: Vec8u16 = @splat(127);
    const div_255: Vec8u16 = @splat(255);

    var out_idx: usize = 0;
    for (0..h) |y| {
        const row = rgba_pixels[y * pitch .. y * pitch + w * 4];
        var x: usize = 0;
        while (x + 8 <= w) : (x += 8) {
            const base = x * 4;
            var rv: [8]u8 = undefined;
            var gv: [8]u8 = undefined;
            var bv: [8]u8 = undefined;
            var av: [8]u8 = undefined;
            inline for (0..8) |i| {
                rv[i] = row[base + i * 4 + 0];
                gv[i] = row[base + i * 4 + 1];
                bv[i] = row[base + i * 4 + 2];
                av[i] = row[base + i * 4 + 3];
            }
            var r_vec: Vec8u8 = rv;
            var g_vec: Vec8u8 = gv;
            var b_vec: Vec8u8 = bv;
            const a_vec: Vec8u8 = av;

            if (!@reduce(.And, a_vec == opaque_mask)) {
                const a16: Vec8u16 = a_vec;
                const r16: Vec8u16 = r_vec;
                const g16: Vec8u16 = g_vec;
                const b16: Vec8u16 = b_vec;
                r_vec = @intCast((r16 * a16 + round_127) / div_255);
                g_vec = @intCast((g16 * a16 + round_127) / div_255);
                b_vec = @intCast((b16 * a16 + round_127) / div_255);
            }

            const r_key: Vec8u16 = r_vec >> @as(Vec8u8, @splat(3));
            const g_key: Vec8u16 = g_vec >> @as(Vec8u8, @splat(3));
            const b_key: Vec8u16 = b_vec >> @as(Vec8u8, @splat(3));
            const keys: [8]u16 = (r_key << @as(@Vector(8, u4), @splat(10))) |
                (g_key << @as(@Vector(8, u4), @splat(5))) |
                b_key;

            const r_arr: [8]u8 = r_vec;
            const g_arr: [8]u8 = g_vec;
            const b_arr: [8]u8 = b_vec;

            inline for (0..8) |i| {
                const r = r_arr[i];
                const g = g_arr[i];
                const b = b_arr[i];
                rgb_buf[out_idx + 0] = r;
                rgb_buf[out_idx + 1] = g;
                rgb_buf[out_idx + 2] = b;
                out_idx += 3;

                const entry = &hist[keys[i]];
                entry.count += 1;
                entry.r_sum += r;
                entry.g_sum += g;
                entry.b_sum += b;
            }
        }

        while (x < w) : (x += 1) {
            const base = x * 4;
            const a = row[base + 3];
            const r = if (a == 255)
                row[base + 0]
            else
                premultiplyChannel(row[base + 0], a);
            const g = if (a == 255)
                row[base + 1]
            else
                premultiplyChannel(row[base + 1], a);
            const b = if (a == 255)
                row[base + 2]
            else
                premultiplyChannel(row[base + 2], a);

            rgb_buf[out_idx + 0] = r;
            rgb_buf[out_idx + 1] = g;
            rgb_buf[out_idx + 2] = b;
            out_idx += 3;

            const entry = &hist[rgbToKey(r, g, b)];
            entry.count += 1;
            entry.r_sum += r;
            entry.g_sum += g;
            entry.b_sum += b;
        }
    }
}

fn computeBox(buckets: []const Bucket, start: usize, end: usize) ColorBox {
    var r_min: u8 = 255;
    var r_max: u8 = 0;
    var g_min: u8 = 255;
    var g_max: u8 = 0;
    var b_min: u8 = 255;
    var b_max: u8 = 0;
    var total: u64 = 0;
    for (buckets[start..end]) |bk| {
        r_min = @min(r_min, bk.r);
        r_max = @max(r_max, bk.r);
        g_min = @min(g_min, bk.g);
        g_max = @max(g_max, bk.g);
        b_min = @min(b_min, bk.b);
        b_max = @max(b_max, bk.b);
        total += bk.count;
    }
    return .{
        .start = start,
        .end = end,
        .count = total,
        .r_min = r_min,
        .r_max = r_max,
        .g_min = g_min,
        .g_max = g_max,
        .b_min = b_min,
        .b_max = b_max,
    };
}

fn sortBucketsByAxis(buckets: []Bucket, axis: u2) void {
    const Ctx = struct {
        fn lessR(_: void, a: Bucket, b: Bucket) bool {
            return a.r < b.r;
        }
        fn lessG(_: void, a: Bucket, b: Bucket) bool {
            return a.g < b.g;
        }
        fn lessB(_: void, a: Bucket, b: Bucket) bool {
            return a.b < b.b;
        }
    };
    switch (axis) {
        0 => std.mem.sortUnstable(Bucket, buckets, {}, Ctx.lessR),
        1 => std.mem.sortUnstable(Bucket, buckets, {}, Ctx.lessG),
        2 => std.mem.sortUnstable(Bucket, buckets, {}, Ctx.lessB),
        3 => unreachable,
    }
}

/// Runs Median-Cut quantization on `hist` to produce up to 256 palette
/// colors and seeds `lut` for direct histogram keys.
fn buildPaletteMedianCut(
    allocator: std.mem.Allocator,
    hist: []const HistEntry,
    lut: []u16,
) !Palette {
    var non_empty: usize = 0;
    for (hist) |e| {
        if (e.count > 0) non_empty += 1;
    }
    var pal: Palette = .{};
    if (non_empty == 0) {
        pal.len = 1;
        return pal;
    }

    const buckets = try allocator.alloc(Bucket, non_empty);
    defer allocator.free(buckets);

    var idx: usize = 0;
    for (hist, 0..) |e, k| {
        if (e.count == 0) continue;
        buckets[idx] = .{
            .key = @intCast(k),
            .count = e.count,
            .r = @intCast((@as(u64, e.r_sum) + e.count / 2) / e.count),
            .g = @intCast((@as(u64, e.g_sum) + e.count / 2) / e.count),
            .b = @intCast((@as(u64, e.b_sum) + e.count / 2) / e.count),
        };
        idx += 1;
    }

    var boxes: [max_colors]ColorBox = undefined;
    var box_count: usize = 1;
    boxes[0] = computeBox(buckets, 0, buckets.len);

    while (box_count < max_colors) {
        var best_idx: ?usize = null;
        var best_score: u64 = 0;
        for (boxes[0..box_count], 0..) |box, bi| {
            const score = box.splitScore();
            if (score > best_score) {
                best_score = score;
                best_idx = bi;
            }
        }
        const split_i = best_idx orelse break;
        const box = boxes[split_i];

        sortBucketsByAxis(buckets[box.start..box.end], box.longestAxis());

        const half = box.count / 2;
        var accum: u64 = 0;
        var mid = box.start + 1;
        while (mid < box.end - 1) : (mid += 1) {
            accum += buckets[mid - 1].count;
            if (accum >= half) break;
        }

        boxes[split_i] = computeBox(buckets, box.start, mid);
        boxes[box_count] = computeBox(buckets, mid, box.end);
        box_count += 1;
    }

    pal.len = box_count;
    for (boxes[0..box_count], 0..) |box, pi| {
        var r_sum: u64 = 0;
        var g_sum: u64 = 0;
        var b_sum: u64 = 0;
        var total: u64 = 0;
        for (buckets[box.start..box.end]) |bk| {
            const e = hist[bk.key];
            r_sum += e.r_sum;
            g_sum += e.g_sum;
            b_sum += e.b_sum;
            total += e.count;
            lut[bk.key] = @intCast(pi);
        }
        if (total > 0) {
            pal.r[pi] = @intCast((r_sum + total / 2) / total);
            pal.g[pi] = @intCast((g_sum + total / 2) / total);
            pal.b[pi] = @intCast((b_sum + total / 2) / total);
        }
    }
    return pal;
}

/// Finds the nearest palette index for `(r, g, b)` using 16-wide SIMD
/// squared Euclidean distance comparisons across the SoA palette arrays.
fn findNearestPaletteSimd(pal: *const Palette, r: i16, g: i16, b: i16) u8 {
    const Vec16i32 = @Vector(16, i32);
    const rv: Vec16i32 = @splat(@as(i32, r));
    const gv: Vec16i32 = @splat(@as(i32, g));
    const bv: Vec16i32 = @splat(@as(i32, b));

    var best_dist: i32 = std.math.maxInt(i32);
    var best_idx: u8 = 0;

    var i: usize = 0;
    while (i + 16 <= pal.len) : (i += 16) {
        const pr: Vec16i32 = @as(@Vector(16, i16), pal.r[i..][0..16].*);
        const pg: Vec16i32 = @as(@Vector(16, i16), pal.g[i..][0..16].*);
        const pb: Vec16i32 = @as(@Vector(16, i16), pal.b[i..][0..16].*);
        const dr = rv - pr;
        const dg = gv - pg;
        const db = bv - pb;
        const dists = dr * dr + dg * dg + db * db;
        const min_d = @reduce(.Min, dists);
        if (min_d < best_dist) {
            best_dist = min_d;
            const d_arr: [16]i32 = dists;
            inline for (0..16) |lane| {
                if (d_arr[lane] == min_d) {
                    best_idx = @intCast(i + lane);
                    break;
                }
            }
        }
    }

    while (i < pal.len) : (i += 1) {
        const dr = @as(i32, r) - @as(i32, pal.r[i]);
        const dg = @as(i32, g) - @as(i32, pal.g[i]);
        const db = @as(i32, b) - @as(i32, pal.b[i]);
        const d = dr * dr + dg * dg + db * db;
        if (d < best_dist) {
            best_dist = d;
            best_idx = @intCast(i);
        }
    }

    return best_idx;
}

/// Returns the 8-bit RGB center of a 5-bit histogram cell `key` so lazy
/// LUT fills are independent of pixel scan order.
inline fn lutKeyCenter(key: u16) [3]i16 {
    return .{
        @intCast((((key >> 10) & 31) << 3) | 4),
        @intCast((((key >> 5) & 31) << 3) | 4),
        @intCast(((key & 31) << 3) | 4),
    };
}

/// Maps `rgb_buf` to palette indices using 8-wide SIMD 4x4 Bayer ordered
/// dithering backed by the 5-bit `lut` and 16-wide SIMD nearest-color lookup.
fn ditherBayerSimd(
    rgb_buf: []const u8,
    w: usize,
    h: usize,
    pal: *const Palette,
    lut: []u16,
    indexed: []u8,
) void {
    if (pal.len <= 1) {
        @memset(indexed, 0);
        return;
    }

    const Vec8i16 = @Vector(8, i16);
    const Vec8u16 = @Vector(8, u16);
    const zero: Vec8i16 = @splat(0);
    const max_255: Vec8i16 = @splat(255);

    for (0..h) |y| {
        const bayer_vec = bayer_rows[y & 3];
        const bayer_arr: [8]i16 = bayer_vec;
        const row_base = y * w;
        var x: usize = 0;

        while (x + 8 <= w) : (x += 8) {
            const p_base = (row_base + x) * 3;
            var rv: [8]i16 = undefined;
            var gv: [8]i16 = undefined;
            var bv: [8]i16 = undefined;
            inline for (0..8) |i| {
                rv[i] = rgb_buf[p_base + i * 3 + 0];
                gv[i] = rgb_buf[p_base + i * 3 + 1];
                bv[i] = rgb_buf[p_base + i * 3 + 2];
            }

            const rc = @min(@max(@as(Vec8i16, rv) + bayer_vec, zero), max_255);
            const gc = @min(@max(@as(Vec8i16, gv) + bayer_vec, zero), max_255);
            const bc = @min(@max(@as(Vec8i16, bv) + bayer_vec, zero), max_255);

            const r_u: Vec8u16 = @intCast(rc);
            const g_u: Vec8u16 = @intCast(gc);
            const b_u: Vec8u16 = @intCast(bc);

            const rk = r_u >> @as(@Vector(8, u4), @splat(3));
            const gk = g_u >> @as(@Vector(8, u4), @splat(3));
            const bk = b_u >> @as(@Vector(8, u4), @splat(3));
            const keys: [8]u16 = (rk << @as(@Vector(8, u4), @splat(10))) |
                (gk << @as(@Vector(8, u4), @splat(5))) |
                bk;

            inline for (0..8) |i| {
                const key = keys[i];
                var ci = lut[key];
                if (ci == lut_empty) {
                    const center = lutKeyCenter(key);
                    ci = findNearestPaletteSimd(
                        pal,
                        center[0],
                        center[1],
                        center[2],
                    );
                    lut[key] = ci;
                }
                indexed[row_base + x + i] = @intCast(ci);
            }
        }

        while (x < w) : (x += 1) {
            const p_off = (row_base + x) * 3;
            const d = bayer_arr[x & 3];
            const r = std.math.clamp(@as(i16, rgb_buf[p_off + 0]) + d, 0, 255);
            const g = std.math.clamp(@as(i16, rgb_buf[p_off + 1]) + d, 0, 255);
            const b = std.math.clamp(@as(i16, rgb_buf[p_off + 2]) + d, 0, 255);

            const key = rgbToKey(@intCast(r), @intCast(g), @intCast(b));
            var ci = lut[key];
            if (ci == lut_empty) {
                const center = lutKeyCenter(key);
                ci = findNearestPaletteSimd(
                    pal,
                    center[0],
                    center[1],
                    center[2],
                );
                lut[key] = ci;
            }
            indexed[row_base + x] = @intCast(ci);
        }
    }
}

inline fn mergeColumnBit(
    col_colors: *[6]u8,
    col_masks: *[6]u8,
    col_len: *usize,
    ci: u8,
    comptime bit_mask: u8,
) void {
    const n = col_len.*;
    for (0..n) |j| {
        if (col_colors[j] == ci) {
            col_masks[j] |= bit_mask;
            return;
        }
    }
    col_colors[n] = ci;
    col_masks[n] = bit_mask;
    col_len.* = n + 1;
}

/// Emits one 6-row Sixel band using a single-pass sparse column scan and
/// counting sort (`O(6 * w)`), eliminating per-color full-width rescans.
fn writeSixelBandSparse(
    out: *BandBuf,
    indexed: []const u8,
    w: usize,
    y: usize,
    band_h: usize,
    pal_len: usize,
    raw_entries: []BandEntry,
    sorted_entries: []BandEntry,
) !void {
    var row_slices: [6][]const u8 = undefined;
    for (0..band_h) |bit| {
        const row_start = (y + bit) * w;
        row_slices[bit] = indexed[row_start .. row_start + w];
    }

    var color_counts: [max_colors]u32 = @splat(0);
    var raw_len: usize = 0;

    if (band_h == 6) {
        const r0 = row_slices[0];
        const r1 = row_slices[1];
        const r2 = row_slices[2];
        const r3 = row_slices[3];
        const r4 = row_slices[4];
        const r5 = row_slices[5];
        for (0..w) |x| {
            const c0 = r0[x];
            const c1 = r1[x];
            const c2 = r2[x];
            const c3 = r3[x];
            const c4 = r4[x];
            const c5 = r5[x];
            if (c0 == c1 and c0 == c2 and c0 == c3 and c0 == c4 and c0 == c5) {
                raw_entries[raw_len] = .{
                    .x = @intCast(x),
                    .color = c0,
                    .mask = 0x3F,
                };
                raw_len += 1;
                color_counts[c0] += 1;
                continue;
            }
            var col_colors: [6]u8 = undefined;
            var col_masks: [6]u8 = undefined;
            col_colors[0] = c0;
            col_masks[0] = 1;
            var col_len: usize = 1;
            mergeColumnBit(&col_colors, &col_masks, &col_len, c1, 2);
            mergeColumnBit(&col_colors, &col_masks, &col_len, c2, 4);
            mergeColumnBit(&col_colors, &col_masks, &col_len, c3, 8);
            mergeColumnBit(&col_colors, &col_masks, &col_len, c4, 16);
            mergeColumnBit(&col_colors, &col_masks, &col_len, c5, 32);

            for (0..col_len) |j| {
                const ci = col_colors[j];
                raw_entries[raw_len] = .{
                    .x = @intCast(x),
                    .color = ci,
                    .mask = col_masks[j],
                };
                raw_len += 1;
                color_counts[ci] += 1;
            }
        }
    } else {
        for (0..w) |x| {
            var col_colors: [6]u8 = undefined;
            var col_masks: [6]u8 = undefined;
            var col_len: usize = 0;

            for (0..band_h) |bit| {
                const ci = row_slices[bit][x];
                const bit_mask = @as(u8, 1) << @intCast(bit);
                var merged = false;
                for (0..col_len) |j| {
                    if (col_colors[j] == ci) {
                        col_masks[j] |= bit_mask;
                        merged = true;
                        break;
                    }
                }
                if (!merged) {
                    col_colors[col_len] = ci;
                    col_masks[col_len] = bit_mask;
                    col_len += 1;
                }
            }

            for (0..col_len) |j| {
                const ci = col_colors[j];
                raw_entries[raw_len] = .{
                    .x = @intCast(x),
                    .color = ci,
                    .mask = col_masks[j],
                };
                raw_len += 1;
                color_counts[ci] += 1;
            }
        }
    }

    var offsets: [max_colors]u32 = undefined;
    var cursors: [max_colors]u32 = undefined;
    var sum: u32 = 0;
    for (0..pal_len) |ci| {
        offsets[ci] = sum;
        cursors[ci] = sum;
        sum += color_counts[ci];
    }

    for (raw_entries[0..raw_len]) |entry| {
        const dst = cursors[entry.color];
        sorted_entries[dst] = entry;
        cursors[entry.color] = dst + 1;
    }

    var first_in_band = true;
    for (0..pal_len) |ci| {
        const count = color_counts[ci];
        if (count == 0) continue;

        if (!first_in_band) {
            try out.appendByte('$');
        }
        first_in_band = false;
        try out.appendByte('#');
        try out.appendUint(ci);

        const start = offsets[ci];
        const entries = sorted_entries[start .. start + count];

        var prev_x: i32 = -1;
        var run_ch: u8 = 0;
        var run_len: usize = 0;

        for (entries) |entry| {
            // Reserve a fixed 44-byte window (two 22-byte RLE runs max) once
            // per entry so inner `encodeRleRun` calls write into typed
            // `*[22]u8` slices without unchecked APIs or error propagation.
            const slot = try out.reserve(44);
            var n: usize = 0;
            const cur_x: i32 = entry.x;
            const gap: usize = @intCast(cur_x - prev_x - 1);
            if (gap > 0) {
                if (run_len > 0) {
                    n += BandBuf.encodeRleRun(slot[0..22], run_ch, run_len);
                    run_len = 0;
                }
                n += BandBuf.encodeRleRun(slot[n..][0..22], '?', gap);
            }

            const ch: u8 = 63 + entry.mask;
            if (run_len == 0) {
                run_ch = ch;
                run_len = 1;
            } else if (ch == run_ch) {
                run_len += 1;
            } else {
                n += BandBuf.encodeRleRun(slot[0..22], run_ch, run_len);
                run_ch = ch;
                run_len = 1;
            }
            out.commit(n);
            prev_x = cur_x;
        }
        if (run_len > 0) {
            const slot = try out.reserve(22);
            out.commit(BandBuf.encodeRleRun(slot, run_ch, run_len));
        }
    }
}

/// Encodes `rgba_pixels` (with row stride `pitch` bytes and dimensions `dims`)
/// into a VT340 Sixel DCS sequence (`\x1bP0;1;0q...\x1b\\`) with a 256-color
/// median-cut palette, 8-wide SIMD 4x4 Bayer dithering, and single-pass
/// sparse band packing.
pub fn writeSixelPreview(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
) !void {
    if (dims.w == 0 or dims.h == 0) return error.InvalidDimensions;
    if (dims.w > max_preview_dim or dims.h > max_preview_dim) {
        return error.DimensionsTooLarge;
    }
    const w: usize = @intCast(dims.w);
    const h: usize = @intCast(dims.h);
    const row_bytes = w * 4;
    if (pitch < row_bytes) return error.InvalidPitch;
    if (@as(u64, h - 1) *| @as(u64, pitch) +| row_bytes > rgba_pixels.len) {
        return error.BufferTooSmall;
    }

    const indexed = try allocator.alloc(u8, w * h);
    defer allocator.free(indexed);

    const pal = blk: {
        const rgb_buf = try allocator.alloc(u8, w * h * 3);
        defer allocator.free(rgb_buf);

        const lut = try allocator.alloc(u16, hist_size);
        defer allocator.free(lut);
        @memset(lut, lut_empty);

        const pal = hist_blk: {
            const hist = try allocator.alloc(HistEntry, hist_size);
            defer allocator.free(hist);
            @memset(hist, .{});

            buildHistogramAndRgb(rgba_pixels, pitch, w, h, hist, rgb_buf);
            break :hist_blk try buildPaletteMedianCut(allocator, hist, lut);
        };

        ditherBayerSimd(rgb_buf, w, h, &pal, lut, indexed);
        break :blk pal;
    };

    const band_cap = w * 6;
    const raw_entries = try allocator.alloc(BandEntry, band_cap);
    defer allocator.free(raw_entries);
    const sorted_entries = try allocator.alloc(BandEntry, band_cap);
    defer allocator.free(sorted_entries);

    var out: BandBuf = .{ .writer = writer };

    // DCS header: P1=0, P2=1 (transparent background for 0 bits), P3=0,
    // plus 1:1 raster attributes ("1;1;w;h).
    try out.appendSlice("\x1bP0;1;0q\"1;1;");
    try out.appendUint(w);
    try out.appendByte(';');
    try out.appendUint(h);

    // Emit Sixel RGB palette definitions (0..100 scale).
    for (0..pal.len) |pi| {
        const rp: usize = (@as(usize, @intCast(pal.r[pi])) * 100 + 127) / 255;
        const gp: usize = (@as(usize, @intCast(pal.g[pi])) * 100 + 127) / 255;
        const bp: usize = (@as(usize, @intCast(pal.b[pi])) * 100 + 127) / 255;
        try out.appendByte('#');
        try out.appendUint(pi);
        try out.appendSlice(";2;");
        try out.appendUint(rp);
        try out.appendByte(';');
        try out.appendUint(gp);
        try out.appendByte(';');
        try out.appendUint(bp);
    }

    var y: usize = 0;
    while (y < h) : (y += 6) {
        const band_h = @min(6, h - y);
        try writeSixelBandSparse(
            &out,
            indexed,
            w,
            y,
            band_h,
            pal.len,
            raw_entries,
            sorted_entries,
        );
        if (y + 6 < h) {
            try out.appendByte('-');
        }
    }

    try out.appendSlice("\x1b\\");
    try out.flush();
}

test "writeSixelPreview encodes solid 20x6 image with RLE" {
    const allocator = std.testing.allocator;
    const w: u32 = 20;
    const h: u32 = 6;
    var pixels: [w * h * 4]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i + 0] = 255;
        pixels[i + 1] = 0;
        pixels[i + 2] = 0;
        pixels[i + 3] = 255;
    }

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeSixelPreview(allocator, &aw.writer, &pixels, w * 4, .{
        .w = w,
        .h = h,
    });
    const encoded = aw.written();
    try std.testing.expectEqualStrings(
        "\x1bP0;1;0q\"1;1;20;6#0;2;100;0;0#0!20~\x1b\\",
        encoded,
    );
}

test "writeSixelPreview encodes 2-color horizontal split with gap RLE" {
    const allocator = std.testing.allocator;
    const w: usize = 10;
    const h: usize = 6;
    var pixels: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const off = (y * w + x) * 4;
            const is_right = x >= 5;
            pixels[off + 0] = if (is_right) 0 else 255;
            pixels[off + 1] = if (is_right) 255 else 0;
            pixels[off + 2] = 0;
            pixels[off + 3] = 255;
        }
    }

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeSixelPreview(allocator, &aw.writer, &pixels, w * 4, .{
        .w = w,
        .h = h,
    });
    const encoded = aw.written();
    // Both colors have 5-wide runs; right half starts with a 5-wide '?' gap.
    try std.testing.expect(std.mem.find(u8, encoded, "!5~") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "!5?!5~") != null);
}

test "writeSixelPreview handles multi-band gradient and strided pitch" {
    const allocator = std.testing.allocator;
    const w: usize = 33;
    const h: usize = 13;
    const pitch: usize = w * 4 + 16;
    const pixels = try allocator.alloc(u8, pitch * h);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    for (0..h) |y| {
        for (0..w) |x| {
            const off = y * pitch + x * 4;
            pixels[off + 0] = @intCast((x * 255) / (w - 1));
            pixels[off + 1] = @intCast((y * 255) / (h - 1));
            pixels[off + 2] = @intCast(((x + y) * 255) / (w + h));
            pixels[off + 3] = 255;
        }
    }

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeSixelPreview(allocator, &aw.writer, pixels, pitch, .{
        .w = @intCast(w),
        .h = @intCast(h),
    });
    const encoded = aw.written();
    try std.testing.expect(
        std.mem.startsWith(u8, encoded, "\x1bP0;1;0q\"1;1;33;13"),
    );
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
    // 13 rows -> 3 sixel bands -> exactly 2 band separators ('-').
    var dashes: usize = 0;
    for (encoded) |c| {
        if (c == '-') dashes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dashes);
}

test "writeSixelPreview rejects invalid dims, pitch, and overflow" {
    const allocator = std.testing.allocator;
    var buf: [16]u8 = @splat(255);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try std.testing.expectError(
        error.InvalidDimensions,
        writeSixelPreview(allocator, &aw.writer, &buf, 8, .{ .w = 0, .h = 2 }),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        writeSixelPreview(allocator, &aw.writer, &buf, 8, .{ .w = 2, .h = 0 }),
    );
    try std.testing.expectError(
        error.InvalidPitch,
        writeSixelPreview(allocator, &aw.writer, &buf, 4, .{ .w = 2, .h = 2 }),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        writeSixelPreview(
            allocator,
            &aw.writer,
            buf[0..8],
            8,
            .{ .w = 2, .h = 2 },
        ),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        writeSixelPreview(
            allocator,
            &aw.writer,
            &buf,
            std.math.maxInt(usize),
            .{ .w = 2, .h = 2 },
        ),
    );
}
