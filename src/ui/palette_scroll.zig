const std = @import("std");
const clay = @import("zclay");
const app = @import("app");
const types = app.types;
const MeasureTextUserData = types.MeasureTextUserData;
const text_utils = @import("text_utils.zig");
const truncateFilename = text_utils.truncateFilename;
const truncateFilenameMiddle = text_utils.truncateFilenameMiddle;
const remapMiddleTruncatedMatches = text_utils.remapMiddleTruncatedMatches;
const truncateDirectory = text_utils.truncateDirectory;
const theme = @import("theme.zig");
const palette_items = @import("palette_items.zig");
const renderFuzzyMatchText = palette_items.renderFuzzyMatchText;
const palette_layout = @import("palette_layout.zig");
const PaletteConfig = palette_layout.PaletteConfig;

/// Virtualized window computation for large palette item lists.
/// Calculates the visible index range and spacer element heights to restrict Clay UI tree allocations
/// to only items currently visible in the scroll viewport.
pub const VirtualWindow = struct {
    start_idx: usize,
    end_idx: usize,
    top_spacer_h: f32,
    bottom_spacer_h: f32,

    /// Computes visible start/end item indices and top/bottom spacer heights for virtualized scrolling.
    pub fn compute(
        total_items: usize,
        scroll_offset_y: f32,
        viewport_height: f32,
        item_height: f32,
        gap: f32,
    ) VirtualWindow {
        if (total_items == 0) {
            return .{ .start_idx = 0, .end_idx = 0, .top_spacer_h = 0, .bottom_spacer_h = 0 };
        }

        const visible_top = -scroll_offset_y;
        const visible_bottom = visible_top + viewport_height;

        var start_idx = @as(usize, @intFromFloat(@max(0.0, @floor(visible_top / item_height))));
        var end_idx = @as(usize, @intFromFloat(@max(0.0, @ceil(visible_bottom / item_height))));

        start_idx = if (start_idx > 0) start_idx - 1 else 0;
        end_idx = end_idx + 1;

        if (end_idx > total_items) end_idx = total_items;
        if (start_idx > end_idx) start_idx = end_idx;

        const top_spacer_h = if (start_idx > 0)
            @as(f32, @floatFromInt(start_idx)) * item_height - gap
        else
            0.0;

        const bottom_spacer_h = if (total_items - end_idx > 0)
            @as(f32, @floatFromInt(total_items - end_idx)) * item_height - gap
        else
            0.0;

        return .{
            .start_idx = start_idx,
            .end_idx = end_idx,
            .top_spacer_h = top_spacer_h,
            .bottom_spacer_h = bottom_spacer_h,
        };
    }
};
