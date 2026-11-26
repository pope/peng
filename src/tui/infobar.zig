//! 3-Section Terminal Status Bar (`imv-tui`-style Infobar)
//!
//! Pure, zero-SDL renderer drawing Left (index, triage, filename, dims),
//! Center (zoom, scale mode, GPU filter, rotation, edits), and Right (view
//! filter, slideshow badge, `: palette ? help`) into a 1-row `vaxis.Window`.

const intents = @import("intents");
const std = @import("std");
const triage = @import("triage");
const vaxis = @import("vaxis");

const Classification = triage.Classification;
const TextureScaleMode = intents.TextureScaleMode;
const ViewMode = triage.ViewMode;
const ZoomPreset = intents.ZoomPreset;

const bg_bar: vaxis.Color = .{ .rgb = .{ 30, 30, 46 } };
const fg_text: vaxis.Color = .{ .rgb = .{ 205, 214, 244 } };
const fg_subtext: vaxis.Color = .{ .rgb = .{ 166, 173, 200 } };
const fg_accent: vaxis.Color = .{ .rgb = .{ 137, 180, 250 } };
const fg_pick: vaxis.Color = .{ .rgb = .{ 166, 227, 161 } };
const fg_reject: vaxis.Color = .{ .rgb = .{ 243, 139, 168 } };
const fg_warn: vaxis.Color = .{ .rgb = .{ 249, 226, 175 } };
const fg_mauve: vaxis.Color = .{ .rgb = .{ 203, 166, 247 } };

/// Snapshot of viewer metadata rendered by the 1-row TUI status bar.
pub const InfobarModel = struct {
    visible_pos: ?usize = null,
    visible_count: usize = 0,
    is_loading: bool = false,
    filename: []const u8 = "",
    is_raw_jpeg_pair: bool = false,
    classification: Classification = .unflagged,
    view_mode: ViewMode = .default,
    image_w: u32 = 0,
    image_h: u32 = 0,
    zoom_factor: f32 = 1.0,
    fit_mode: ZoomPreset = .full,
    is_manual_zoom: bool = false,
    scale_filter: TextureScaleMode = .linear,
    rotation_deg: f32 = 0.0,
    has_edits: bool = false,
    compare_original: bool = false,
    slideshow_active: bool = false,
    slideshow_paused: bool = false,
    notification: []const u8 = "",
};

fn scaleLabel(fit_mode: ZoomPreset, is_manual: bool) []const u8 {
    if (is_manual) return "manual";
    return switch (fit_mode) {
        .none => "1:1",
        .shrink => "shrink",
        .full => "fit",
        .crop => "fill",
        .fit_width => "fit-w",
        .fit_height => "fit-h",
    };
}

fn viewModeBadge(mode: ViewMode) ?[]const u8 {
    return switch (mode) {
        .default => null,
        .picks => "[Picks]",
        .rejects => "[Rejects]",
        .unflagged => "[Unflagged]",
        .all => "[All]",
    };
}

/// Returns a valid UTF-8 slice free of ASCII/C1 control characters (`< 0x20`,
/// `0x7F..0x9F`). Borrows `raw` when already clean (using a 16-byte SIMD
/// printable-ASCII fast-path); otherwise allocates a sanitized copy from
/// `allocator` replacing invalid bytes and control characters with `?`.
pub fn sanitizeUtf8(
    allocator: std.mem.Allocator,
    raw: []const u8,
) []const u8 {
    const Vec16 = @Vector(16, u8);
    const ascii_lo: Vec16 = @splat(0x20);
    const ascii_span: Vec16 = @splat(0x7E - 0x20);

    var clean = true;
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 16 <= raw.len) {
            const chunk: Vec16 = raw[i..][0..16].*;
            if (@reduce(.And, (chunk -% ascii_lo) <= ascii_span)) {
                i += 16;
                continue;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            clean = false;
            break;
        };
        if (i + len > raw.len) {
            clean = false;
            break;
        }
        const cp = std.unicode.utf8Decode(raw[i..][0..len]) catch {
            clean = false;
            break;
        };
        if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) {
            clean = false;
            break;
        }
        i += len;
    }
    if (clean) return raw;

    var buf: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < raw.len) {
        const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            buf.append(allocator, '?') catch break;
            i += 1;
            continue;
        };
        if (i + len > raw.len) {
            buf.append(allocator, '?') catch break;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(raw[i..][0..len]) catch {
            buf.append(allocator, '?') catch break;
            i += 1;
            continue;
        };
        if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) {
            buf.append(allocator, '?') catch break;
        } else {
            buf.appendSlice(allocator, raw[i..][0..len]) catch break;
        }
        i += len;
    }
    return buf.items;
}

fn writeTextClipped(
    win: vaxis.Window,
    start_col: u16,
    max_cols: u16,
    text: []const u8,
    style: vaxis.Style,
) u16 {
    if (max_cols == 0 or start_col >= win.width or text.len == 0) return 0;
    const avail = @min(max_cols, win.width - start_col);
    var col: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const slice = grapheme.bytes(text);
        const w_raw = win.gwidth(slice);
        if (w_raw == 0) continue;
        const w: u16 = @intCast(@min(w_raw, std.math.maxInt(u16)));
        if (col +| w > avail) break;
        win.writeCell(start_col + col, 0, .{
            .char = .{
                .grapheme = slice,
                .width = @intCast(@min(w_raw, std.math.maxInt(u8))),
            },
            .style = style,
        });
        col += w;
    }
    return col;
}

const StyledSpan = struct {
    text: []const u8,
    fg: vaxis.Color,
    bold: bool = false,
};

fn spansCellWidth(win: vaxis.Window, spans: []const StyledSpan) u16 {
    var total: usize = 0;
    for (spans) |sp| {
        total += win.gwidth(sp.text);
    }
    return @intCast(@min(total, std.math.maxInt(u16)));
}

fn writeSpans(
    win: vaxis.Window,
    start_col: u16,
    max_cols: u16,
    spans: []const StyledSpan,
) u16 {
    var col = start_col;
    var rem = max_cols;
    for (spans) |sp| {
        if (rem == 0) break;
        const written = writeTextClipped(win, col, rem, sp.text, .{
            .fg = sp.fg,
            .bg = bg_bar,
            .bold = sp.bold,
        });
        col += written;
        rem -|= written;
    }
    return col - start_col;
}

/// Renders the 3-section status bar (Left: index/triage/filename/dims,
/// Center: zoom/scale/filter/rotation/edits, Right: filter/slideshow/hints)
/// into the 1-row `vaxis.Window` `bar`. Formatted strings are allocated from
/// `frame_allocator`, which must outlive the subsequent `vaxis.render` call.
pub fn render(
    bar: vaxis.Window,
    model: InfobarModel,
    frame_allocator: std.mem.Allocator,
) void {
    if (bar.width == 0 or bar.height == 0) return;

    bar.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .fg = fg_text, .bg = bg_bar },
    });

    // --- Right section ---
    var right_spans_buf: [5]StyledSpan = undefined;
    var right_len: usize = 0;

    if (viewModeBadge(model.view_mode)) |badge| {
        right_spans_buf[right_len] = .{
            .text = badge,
            .fg = fg_mauve,
            .bold = true,
        };
        right_len += 1;
        right_spans_buf[right_len] = .{ .text = " ", .fg = fg_subtext };
        right_len += 1;
    }
    if (model.slideshow_active) {
        right_spans_buf[right_len] = .{
            .text = if (model.slideshow_paused) "[PAUSE] " else "[PLAY] ",
            .fg = fg_warn,
            .bold = true,
        };
        right_len += 1;
    }
    right_spans_buf[right_len] = .{
        .text = ": palette  ? help ",
        .fg = fg_subtext,
    };
    right_len += 1;

    const right_spans = right_spans_buf[0..right_len];
    const right_w = spansCellWidth(bar, right_spans);
    const show_right = bar.width >= 28 and right_w +| 4 < bar.width;
    const right_start: u16 = if (show_right) bar.width - right_w else bar.width;
    if (show_right) {
        _ = writeSpans(bar, right_start, right_w, right_spans);
    }

    const left_max = right_start -| 1;
    if (model.notification.len > 0) {
        const clean_msg = sanitizeUtf8(frame_allocator, model.notification);
        const notif_spans = [_]StyledSpan{
            .{ .text = " ", .fg = fg_warn },
            .{ .text = clean_msg, .fg = fg_warn, .bold = true },
        };
        _ = writeSpans(bar, 0, left_max, &notif_spans);
        return;
    }

    // --- Left section ---
    var left_spans_buf: [6]StyledSpan = undefined;
    var left_len: usize = 0;

    if (model.visible_pos) |pos| {
        const idx_str = frame_allocator.print(
            " [{d}/{d}] ",
            .{ pos, model.visible_count },
        ) catch " ";
        left_spans_buf[left_len] = .{
            .text = idx_str,
            .fg = fg_accent,
            .bold = true,
        };
        left_len += 1;

        switch (model.classification) {
            .pick => {
                left_spans_buf[left_len] = .{
                    .text = "* ",
                    .fg = fg_pick,
                    .bold = true,
                };
                left_len += 1;
            },
            .reject => {
                left_spans_buf[left_len] = .{
                    .text = "x ",
                    .fg = fg_reject,
                    .bold = true,
                };
                left_len += 1;
            },
            .unflagged => {},
        }

        if (model.filename.len > 0) {
            left_spans_buf[left_len] = .{
                .text = sanitizeUtf8(frame_allocator, model.filename),
                .fg = fg_text,
            };
            left_len += 1;
        }
        if (model.is_raw_jpeg_pair) {
            left_spans_buf[left_len] = .{
                .text = " [RAW+JPG]",
                .fg = fg_warn,
            };
            left_len += 1;
        }
        if (model.image_w > 0 and model.image_h > 0) {
            const dims_str = frame_allocator.print(
                " {d}x{d}",
                .{ model.image_w, model.image_h },
            ) catch "";
            left_spans_buf[left_len] = .{
                .text = dims_str,
                .fg = fg_subtext,
            };
            left_len += 1;
        }
    } else {
        const msg = if (model.is_loading)
            " Loading images..."
        else
            " No images";
        left_spans_buf[left_len] = .{ .text = msg, .fg = fg_subtext };
        left_len += 1;
    }

    const left_written = writeSpans(
        bar,
        0,
        left_max,
        left_spans_buf[0..left_len],
    );

    if (model.visible_pos == null) return;

    // --- Center section (drawn only when space fits between Left & Right) ---
    var center_spans_buf: [3]StyledSpan = undefined;
    var center_len: usize = 0;

    const zoom_pct: u32 = if (std.math.isFinite(model.zoom_factor) and
        model.zoom_factor > 0.0)
        @intFromFloat(@min(@round(model.zoom_factor * 100.0), 99999.0))
    else
        100;
    const rot_norm: i32 = if (std.math.isFinite(model.rotation_deg))
        @intFromFloat(@mod(@round(model.rotation_deg), 360.0))
    else
        0;
    const base_str = if (rot_norm != 0)
        frame_allocator.print(
            "{d}% {s} · {s} · {d}deg",
            .{
                zoom_pct,
                scaleLabel(model.fit_mode, model.is_manual_zoom),
                model.scale_filter.shortLabel(),
                rot_norm,
            },
        ) catch ""
    else
        frame_allocator.print(
            "{d}% {s} · {s}",
            .{
                zoom_pct,
                scaleLabel(model.fit_mode, model.is_manual_zoom),
                model.scale_filter.shortLabel(),
            },
        ) catch "";
    center_spans_buf[center_len] = .{ .text = base_str, .fg = fg_subtext };
    center_len += 1;

    if (model.compare_original) {
        center_spans_buf[center_len] = .{
            .text = " [ORIG]",
            .fg = fg_warn,
            .bold = true,
        };
        center_len += 1;
    } else if (model.has_edits) {
        center_spans_buf[center_len] = .{
            .text = " [EDITED]",
            .fg = fg_accent,
            .bold = true,
        };
        center_len += 1;
    }

    const center_spans = center_spans_buf[0..center_len];
    const center_w = spansCellWidth(bar, center_spans);
    const min_center_start = left_written +| 2;
    if (right_start > min_center_start +| center_w +| 1) {
        const ideal_start = (bar.width -| center_w) / 2;
        const clamped_start = @max(
            min_center_start,
            @min(ideal_start, right_start -| (center_w +| 2)),
        );
        _ = writeSpans(bar, clamped_start, center_w, center_spans);
    }
}

fn readRowText(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var c: u16 = 0;
    while (c < win.width) {
        const cell = win.readCell(c, 0).?;
        try out.appendSlice(allocator, cell.char.grapheme);
        c += @max(@as(u16, 1), @as(u16, cell.char.width));
    }
    return out.toOwnedSlice(allocator);
}

test "infobar.render renders all 3 sections on wide terminals" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 140,
        .rows = 1,
        .x_pixel = 1400,
        .y_pixel = 20,
    });
    defer screen.deinit(allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 140,
        .height = 1,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    render(win, .{
        .visible_pos = 3,
        .visible_count = 42,
        .filename = "photo.arw",
        .is_raw_jpeg_pair = true,
        .classification = .pick,
        .view_mode = .picks,
        .image_w = 6000,
        .image_h = 4000,
        .zoom_factor = 1.5,
        .fit_mode = .full,
        .is_manual_zoom = true,
        .scale_filter = .lanczos3,
        .rotation_deg = 90.0,
        .has_edits = true,
        .slideshow_active = true,
    }, arena.allocator());

    const line = try readRowText(allocator, win);
    defer allocator.free(line);

    try std.testing.expect(std.mem.find(u8, line, "[3/42]") != null);
    try std.testing.expect(std.mem.find(u8, line, "* photo.arw") != null);
    try std.testing.expect(std.mem.find(u8, line, "[RAW+JPG]") != null);
    try std.testing.expect(std.mem.find(u8, line, "6000x4000") != null);
    try std.testing.expect(std.mem.find(u8, line, "150% manual") != null);
    try std.testing.expect(std.mem.find(u8, line, "Lanczos3") != null);
    try std.testing.expect(std.mem.find(u8, line, "90deg") != null);
    try std.testing.expect(std.mem.find(u8, line, "[EDITED]") != null);
    try std.testing.expect(std.mem.find(u8, line, "[Picks]") != null);
    try std.testing.expect(std.mem.find(u8, line, "[PLAY]") != null);
    try std.testing.expect(std.mem.find(u8, line, ": palette") != null);
}

test "infobar.render clips cleanly on narrow 40-col terminals" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 40,
        .rows = 1,
        .x_pixel = 400,
        .y_pixel = 20,
    });
    defer screen.deinit(allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 1,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    render(win, .{
        .visible_pos = 1,
        .visible_count = 5,
        .filename = "very_long_filename_that_exceeds_bar.jpg",
        .classification = .reject,
    }, arena.allocator());

    const line = try readRowText(allocator, win);
    defer allocator.free(line);

    try std.testing.expect(std.mem.find(u8, line, "[1/5] x ") != null);
    try std.testing.expect(std.mem.find(u8, line, ": palette") != null);
}

test "infobar.render sanitizes invalid UTF-8, control chars, CJK, and NaN" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 15,
        .rows = 1,
        .x_pixel = 150,
        .y_pixel = 20,
    });
    defer screen.deinit(allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 15,
        .height = 1,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Invalid UTF-8 (\xFF) + ESC control byte (\x1B) + wide CJK chars.
    render(win, .{
        .visible_pos = 1,
        .visible_count = 1,
        .filename = "\x1b\xff日本写真",
        .zoom_factor = std.math.nan(f32),
        .rotation_deg = std.math.inf(f32),
    }, arena.allocator());

    const line = try readRowText(allocator, win);
    defer allocator.free(line);

    try std.testing.expect(std.mem.find(u8, line, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, line, "[1/1] ??日") != null);

    // SIMD fast-path borrows long clean ASCII zero-copy and catches late DEL.
    const long_clean = "0123456789abcdef_long_ascii_filename.jpg";
    const borrowed = sanitizeUtf8(arena.allocator(), long_clean);
    try std.testing.expectEqual(long_clean.ptr, borrowed.ptr);

    const late_ctrl = "0123456789abcdef_before_\x7f_after.jpg";
    const cleaned = sanitizeUtf8(arena.allocator(), late_ctrl);
    try std.testing.expectEqualStrings(
        "0123456789abcdef_before_?_after.jpg",
        cleaned,
    );
}

test "infobar.render displays sanitized notification and restores on clear" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 80,
        .rows = 1,
        .x_pixel = 800,
        .y_pixel = 20,
    });
    defer screen.deinit(allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 1,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Renders notification even when visible_pos is null and strips ESC bytes.
    render(win, .{
        .notification = "Pre-cached 12 thumbnails\x1b!",
    }, arena.allocator());
    const notif_line = try readRowText(allocator, win);
    defer allocator.free(notif_line);
    try std.testing.expect(std.mem.find(u8, notif_line, "\x1b") == null);
    try std.testing.expect(
        std.mem.find(u8, notif_line, "Pre-cached 12 thumbnails?!") != null,
    );
    try std.testing.expect(std.mem.find(u8, notif_line, ": palette") != null);

    // Clearing notification restores normal metadata.
    render(win, .{
        .visible_pos = 1,
        .visible_count = 12,
        .filename = "photo.jpg",
    }, arena.allocator());
    const normal_line = try readRowText(allocator, win);
    defer allocator.free(normal_line);
    try std.testing.expect(
        std.mem.find(u8, normal_line, "[1/12] photo.jpg") != null,
    );
}
