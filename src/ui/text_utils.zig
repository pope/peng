const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");
const types = @import("../app/types.zig");
const MeasureTextUserData = types.MeasureTextUserData;
const sdl3MeasureText = @import("graphics.zig").sdl3MeasureText;

pub fn truncateFilename(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    const font = data.fonts[0] orelse return text;
    const target_size = @as(f32, @floatFromInt(font_size));
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(allocator, text) orelse return text;
    if (@as(f32, @floatFromInt(size.w)) <= max_w) {
        return text;
    }

    const dots_size = font.getStringSize(allocator, "...") orelse sdl.Font.TextSize{ .w = 0, .h = 0 };

    const available_w = max_w - @as(f32, @floatFromInt(dots_size.w));
    if (available_w <= 0) return "...";

    if (font.measureString(allocator, text, @intFromFloat(available_w))) |m| {
        var best_len = m.measured_len;
        while (best_len > 0 and best_len < text.len and (text[best_len] & 0xC0) == 0x80) {
            best_len -= 1;
        }
        return std.fmt.allocPrint(allocator, "{s}...", .{text[0..best_len]}) catch text;
    }
    return text;
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
