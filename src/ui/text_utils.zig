const clay = @import("zclay");
const sdl = @import("sdl");
const std = @import("std");
const theme = @import("theme.zig");

/// User data context passed to Clay text measurement callbacks containing
/// font handles and debug flags.
pub const MeasureTextUserData = struct {
    fonts: []const ?sdl.Font,
    is_debug_measuring: bool = false,
    allocator: std.mem.Allocator = undefined,
};

/// Measures text pixel width and height via SDL_ttf for Clay layout element
/// sizing.
pub fn sdl3MeasureText(
    text: []const u8,
    config: *clay.TextElementConfig,
    data: *const MeasureTextUserData,
) clay.Dimensions {
    const clean_text = if (std.mem.findScalar(u8, text, 0)) |idx|
        text[0..idx]
    else
        text;
    if (clean_text.len == 0) return .{ .w = 0, .h = 0 };

    if (config.font_id >= data.fonts.len) return .{ .w = 0, .h = 0 };
    const font = data.fonts[config.font_id] orelse return .{ .w = 0, .h = 0 };
    var target_size = @as(f32, @floatFromInt(config.font_size));
    if (data.is_debug_measuring) {
        // Scale down hardcoded 16px Clay debug text to 12px (0.75x) during
        // debug panel layout
        target_size *= theme.debug_font_scale;
    }
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(clean_text) orelse
        return .{ .w = 0, .h = 0 };
    return .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
}

/// Result of middle-truncating a filename, containing the display string and
/// index boundaries for fuzzy match remapping.
pub const TruncatedFilename = struct {
    display: []const u8,
    head_len: usize,
    tail_start_idx: usize,
};

/// Truncates a filename in the middle with an ellipsis ("...") so that
/// rendered text does not exceed `max_w` pixels.
pub fn truncateFilenameMiddle(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_w: f32,
    font_size: u16,
    data: *const MeasureTextUserData,
) TruncatedFilename {
    const font = data.fonts[0] orelse return .{
        .display = text,
        .head_len = text.len,
        .tail_start_idx = text.len,
    };
    const target_size = @as(f32, @floatFromInt(font_size));
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(text) orelse return .{
        .display = text,
        .head_len = text.len,
        .tail_start_idx = text.len,
    };
    if (@as(f32, @floatFromInt(size.w)) <= max_w) {
        return .{ .display = text, .head_len = text.len, .tail_start_idx = text.len };
    }

    const dots_size = font.getStringSize("...") orelse
        sdl.Font.TextSize{ .w = 0, .h = 0 };

    const available_w = max_w - @as(f32, @floatFromInt(dots_size.w));
    if (available_w <= 0) return .{ .display = "...", .head_len = 0, .tail_start_idx = text.len };

    const half_w = available_w / 2.0;

    var head_len: usize = 0;
    var head_w: f32 = 0.0;
    if (font.measureString(text, @intFromFloat(half_w))) |m| {
        head_len = m.measured_len;
        head_w = @as(f32, @floatFromInt(m.measured_w));
        while (head_len > 0 and head_len < text.len and (text[head_len] & 0xC0) == 0x80) {
            head_len -= 1;
        }
    }

    const tail_available_w = available_w - head_w;

    var tail_len: usize = 0;
    var low: usize = 0;
    var high: usize = if (text.len > head_len) text.len - head_len else 0;

    while (low <= high) {
        const mid = (low + high) / 2;
        const start_idx = text.len - mid;
        var byte_start = start_idx;
        while (byte_start < text.len and (text[byte_start] & 0xC0) == 0x80) {
            byte_start += 1;
        }

        const suffix = text[byte_start..];
        const suf_size = font.getStringSize(suffix) orelse
            sdl.Font.TextSize{ .w = 0, .h = 0 };
        if (@as(f32, @floatFromInt(suf_size.w)) <= tail_available_w) {
            tail_len = text.len - byte_start;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    var tail_start_idx = text.len - tail_len;
    if (tail_start_idx < head_len) {
        tail_start_idx = head_len;
    }

    const display = allocator.print(
        "{s}...{s}",
        .{ text[0..head_len], text[tail_start_idx..] },
    ) catch return .{
        .display = text,
        .head_len = text.len,
        .tail_start_idx = text.len,
    };

    return .{
        .display = display,
        .head_len = head_len,
        .tail_start_idx = tail_start_idx,
    };
}

/// Truncates a filename in the middle with an ellipsis ("...") returning only the display string.
pub fn truncateFilename(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_w: f32,
    font_size: u16,
    data: *const MeasureTextUserData,
) []const u8 {
    return truncateFilenameMiddle(allocator, text, max_w, font_size, data).display;
}

/// Truncates a directory path from the left with leading "..." so that
/// rendered text fits within `max_w` pixels.
pub fn truncateDirectory(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_w: f32,
    font_size: u16,
    data: *const MeasureTextUserData,
) []const u8 {
    var text_config = clay.TextElementConfig{
        .font_id = 0,
        .font_size = font_size,
    };

    const initial_dim = sdl3MeasureText(text, &text_config, data);
    if (initial_dim.w <= max_w) {
        return text;
    }

    const dots_w = sdl3MeasureText("...", &text_config, data).w;

    var low: usize = 0;
    var high: usize = text.len;
    var best_len: usize = 0;

    while (low <= high) {
        const mid = (low + high) / 2;
        const start_idx = text.len - mid;
        // Verify UTF-8 boundary
        var byte_start = start_idx;
        while (byte_start < text.len and (text[byte_start] & 0xC0) == 0x80) {
            byte_start += 1;
        }

        const part_w = sdl3MeasureText(text[byte_start..], &text_config, data).w;

        if (part_w + dots_w <= max_w) {
            best_len = text.len - byte_start;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    return allocator.print(
        "...{s}",
        .{text[text.len - best_len ..]},
    ) catch text;
}

/// Formats a byte size as a fractional megabyte string (e.g. "1.5 MB").
pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mb = kb / 1024.0;
    return allocator.print("{d:.1} MB", .{mb});
}

test "formatSize" {
    const str = try formatSize(std.testing.allocator, 1048576);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("1.0 MB", str);
}

test "truncateFilename fallback without fonts" {
    const data = MeasureTextUserData{
        .fonts = &.{null},
        .allocator = std.testing.allocator,
    };
    const res = truncateFilename(std.testing.allocator, "very_long_filename.png", 100.0, 16, &data);
    try std.testing.expectEqualStrings("very_long_filename.png", res);
}

test "truncateDirectory fallback without fonts" {
    const data = MeasureTextUserData{
        .fonts = &.{null},
        .allocator = std.testing.allocator,
    };
    const res = truncateDirectory(
        std.testing.allocator,
        "/long/path/to/folder",
        100.0,
        13,
        &data,
    );
    try std.testing.expectEqualStrings("/long/path/to/folder", res);
}
