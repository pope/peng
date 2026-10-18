const std = @import("std");
const clay = @import("zclay");
const theme = @import("theme.zig");

/// Represents a slice of text tagged with whether it matched a fuzzy search
/// query.
pub const TextChunk = struct {
    slice: []const u8,
    is_matched: bool,
};

fn appendOrMergeChunk(
    list: *std.ArrayList(TextChunk),
    allocator: std.mem.Allocator,
    slice: []const u8,
    is_matched: bool,
) !void {
    if (slice.len == 0) return;
    if (list.items.len > 0 and
        list.items[list.items.len - 1].is_matched == is_matched)
    {
        const last = &list.items[list.items.len - 1];
        const combined_len = last.slice.len + slice.len;
        last.slice = last.slice.ptr[0..combined_len];
    } else {
        try list.append(allocator, .{
            .slice = slice,
            .is_matched = is_matched,
        });
    }
}

/// Partitions a string into contiguous matched and unmatched TextChunk slices
/// for fuzzy search highlighting.
pub fn partitionHighlightedText(
    allocator: std.mem.Allocator,
    text: []const u8,
    match_indices: []const usize,
) ![]TextChunk {
    if (text.len == 0 or match_indices.len == 0) {
        if (text.len == 0) return &.{};
        var list: std.ArrayList(TextChunk) = try .initCapacity(allocator, 1);
        list.appendAssumeCapacity(.{ .slice = text, .is_matched = false });
        return list.toOwnedSlice(allocator);
    }

    for (match_indices) |m_idx| {
        if (m_idx >= text.len) {
            std.log.warn(
                "Fuzzy highlight match index {} out of bounds for " ++
                    "string '{s}' (length {})",
                .{ m_idx, text, text.len },
            );
        }
    }

    var list: std.ArrayList(TextChunk) = .empty;
    errdefer list.deinit(allocator);

    var idx: usize = 0;
    var match_ptr: usize = 0;

    while (idx < text.len) {
        while (match_ptr < match_indices.len and
            match_indices[match_ptr] < idx)
        {
            match_ptr += 1;
        }

        const start = idx;
        idx += 1;
        while (idx < text.len and (text[idx] & 0xC0) == 0x80) {
            idx += 1;
        }
        const is_matched = (match_ptr < match_indices.len and
            match_indices[match_ptr] < idx);

        if (is_matched) {
            while (match_ptr < match_indices.len and
                match_indices[match_ptr] < idx)
            {
                match_ptr += 1;
            }
            while (idx < text.len and match_ptr < match_indices.len) {
                var next_end = idx + 1;
                while (next_end < text.len and
                    (text[next_end] & 0xC0) == 0x80)
                {
                    next_end += 1;
                }
                if (match_indices[match_ptr] >= next_end) break;
                idx = next_end;
                while (match_ptr < match_indices.len and
                    match_indices[match_ptr] < idx)
                {
                    match_ptr += 1;
                }
            }

            var match_start = start;
            var match_end = idx;

            while (match_start < match_end and
                std.ascii.isWhitespace(text[match_start]))
            {
                match_start += 1;
            }
            while (match_end > match_start and
                std.ascii.isWhitespace(text[match_end - 1]))
            {
                match_end -= 1;
            }

            if (match_start > start) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[start..match_start],
                    false,
                );
            }
            if (match_end > match_start) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[match_start..match_end],
                    true,
                );
            }
            if (idx > match_end) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[match_end..idx],
                    false,
                );
            }
        } else {
            try appendOrMergeChunk(
                &list,
                allocator,
                text[start..idx],
                false,
            );
        }
    }

    return try list.toOwnedSlice(allocator);
}

/// Emits Clay text elements partitioning characters into alternating normal
/// and highlighted segments based on fuzzy match indices.
pub fn renderFuzzyMatchText(
    allocator: std.mem.Allocator,
    text: []const u8,
    match_indices: []const usize,
    font_size: u16,
    normal_color: clay.Color,
    highlight_color: clay.Color,
) void {
    if (text.len == 0) return;
    if (match_indices.len == 0) {
        clay.text(text, .{
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
            .wrap_mode = .none,
        });
        return;
    }

    const chunks = partitionHighlightedText(
        allocator,
        text,
        match_indices,
    ) catch |err| {
        std.log.err(
            "partitionHighlightedText failed for '{s}': {}",
            .{ text, err },
        );
        clay.text(text, .{
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
            .wrap_mode = .none,
        });
        return;
    };
    defer allocator.free(chunks);

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        for (chunks) |chunk| {
            const chunk_color =
                if (chunk.is_matched) highlight_color else normal_color;
            clay.text(chunk.slice, .{
                .color = chunk_color,
                .font_size = font_size,
                .font_id = 0,
                .wrap_mode = .none,
            });
        }
    });
}
