const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");
const types = @import("../app/types.zig");
const MeasureTextUserData = types.MeasureTextUserData;
const sdl3MeasureText = @import("graphics.zig").sdl3MeasureText;

pub const TruncatedFilename = struct {
    display: []const u8,
    head_len: usize,
    tail_start_idx: usize,
};

pub fn truncateFilenameMiddle(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) TruncatedFilename {
    const font = data.fonts[0] orelse return .{ .display = text, .head_len = text.len, .tail_start_idx = text.len };
    const target_size = @as(f32, @floatFromInt(font_size));
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(allocator, text) orelse return .{ .display = text, .head_len = text.len, .tail_start_idx = text.len };
    if (@as(f32, @floatFromInt(size.w)) <= max_w) {
        return .{ .display = text, .head_len = text.len, .tail_start_idx = text.len };
    }

    const dots_size = font.getStringSize(allocator, "...") orelse sdl.Font.TextSize{ .w = 0, .h = 0 };

    const available_w = max_w - @as(f32, @floatFromInt(dots_size.w));
    if (available_w <= 0) return .{ .display = "...", .head_len = 0, .tail_start_idx = text.len };

    const half_w = available_w / 2.0;

    var head_len: usize = 0;
    var head_w: f32 = 0.0;
    if (font.measureString(allocator, text, @intFromFloat(half_w))) |m| {
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
        const suf_size = font.getStringSize(allocator, suffix) orelse sdl.Font.TextSize{ .w = 0, .h = 0 };
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

    const display = std.fmt.allocPrint(allocator, "{s}...{s}", .{ text[0..head_len], text[tail_start_idx..] }) catch text;

    return .{
        .display = display,
        .head_len = head_len,
        .tail_start_idx = tail_start_idx,
    };
}

pub fn truncateFilename(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    return truncateFilenameMiddle(allocator, text, max_w, font_size, data).display;
}

pub fn remapMiddleTruncatedMatches(
    allocator: std.mem.Allocator,
    matches: []const usize,
    head_len: usize,
    tail_start_idx: usize,
) ![]usize {
    if (matches.len == 0) return &.{};

    const actual_tail_start = @max(tail_start_idx, head_len);
    var list: std.ArrayList(usize) = try .initCapacity(allocator, matches.len);
    errdefer list.deinit(allocator);

    for (matches) |m_idx| {
        if (m_idx < head_len) {
            list.appendAssumeCapacity(m_idx);
        } else if (m_idx >= actual_tail_start) {
            list.appendAssumeCapacity((m_idx - actual_tail_start) + head_len + 3);
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn truncateDirectory(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
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

    return std.fmt.allocPrint(allocator, "...{s}", .{text[text.len - best_len ..]}) catch text;
}

pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mb = kb / 1024.0;
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{mb});
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

test "remapMiddleTruncatedMatches head, tail, and truncated middle" {
    const matches = [_]usize{ 2, 5, 20, 25, 60, 61 };
    const head_len: usize = 10;
    const tail_start_idx: usize = 50;

    const remapped = try remapMiddleTruncatedMatches(std.testing.allocator, &matches, head_len, tail_start_idx);
    defer std.testing.allocator.free(remapped);

    // 2 < 10 -> 2
    // 5 < 10 -> 5
    // 20 and 25 are in [10, 50) -> dropped
    // 60 >= 50 -> (60 - 50) + 10 + 3 = 23
    // 61 >= 50 -> (61 - 50) + 10 + 3 = 24
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 5, 23, 24 }, remapped);
}

test "remapMiddleTruncatedMatches clamps overlapping tail_start_idx < head_len" {
    const matches = [_]usize{ 3, 7, 12 };
    const head_len: usize = 10;
    const tail_start_idx: usize = 5; // tail_start_idx < head_len

    const remapped = try remapMiddleTruncatedMatches(std.testing.allocator, &matches, head_len, tail_start_idx);
    defer std.testing.allocator.free(remapped);

    // actual_tail_start becomes max(5, 10) = 10
    // 3 < 10 -> 3
    // 7 < 10 -> 7
    // 12 >= 10 -> (12 - 10) + 10 + 3 = 15
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 7, 15 }, remapped);
}
