//! Terminal Viewport Layout & Halfblocks Window Blitter
//!
//! Pure, zero-SDL layout math mapping `vaxis.Winsize` and `InfobarPosition` to
//! image/infobar cell rectangles and pixel dimensions, plus a cell-level
//! Unicode half-block (`▀`) blitter targeting `vaxis.Window`.

const geom = @import("geom");
const std = @import("std");
const termgfx = @import("termgfx");
const vaxis = @import("vaxis");

const CellPixelSize = termgfx.CellPixelSize;
const FRect = geom.FRect;
const PositiveDimsU32 = geom.PositiveDimsU32;

const upper_half_block = "\xe2\x96\x80";

/// Placement of the 1-row status bar inside the terminal viewport.
pub const InfobarPosition = enum {
    bottom,
    top,
    none,

    /// Cycles infobar placement (`bottom` -> `top` -> `none` -> `bottom`).
    pub fn next(self: InfobarPosition) InfobarPosition {
        return switch (self) {
            .bottom => .top,
            .top => .none,
            .none => .bottom,
        };
    }
};

/// Cell-aligned sub-rectangle of `ViewportLayout`'s image area, used to crop
/// offscreen GPU readbacks and terminal graphics transfers to the visible
/// image bounds (excluding empty letterbox margins).
pub const ImageCellCrop = struct {
    col_off: u16,
    row_off: u16,
    cols: u16,
    rows: u16,
    px: PositiveDimsU32,

    /// Pixel X offset of `col_off` within the full image viewport.
    pub fn pxOffsetX(self: ImageCellCrop, cell_px: CellPixelSize) f32 {
        return @floatFromInt(@as(u32, self.col_off) * @as(u32, cell_px.w));
    }

    /// Pixel Y offset of `row_off` within the full image viewport.
    pub fn pxOffsetY(self: ImageCellCrop, cell_px: CellPixelSize) f32 {
        return @floatFromInt(@as(u32, self.row_off) * @as(u32, cell_px.h));
    }

    /// Returns the child `vaxis.Window` inside `image_win` corresponding to
    /// this cropped cell rectangle.
    pub fn subWindow(
        self: ImageCellCrop,
        image_win: vaxis.Window,
    ) vaxis.Window {
        return image_win.child(.{
            .x_off = self.col_off,
            .y_off = self.row_off,
            .width = self.cols,
            .height = self.rows,
        });
    }

    /// Returns `true` when two crops have identical cell and pixel bounds.
    pub fn eql(a: ImageCellCrop, b: ImageCellCrop) bool {
        return std.meta.eql(a, b);
    }
};

/// Computed terminal cell layout and pixel dimensions for one frame.
pub const ViewportLayout = struct {
    cols: u16,
    rows: u16,
    image_row: u16,
    image_cols: u16,
    image_rows: u16,
    infobar_row: ?u16,
    cell_px: CellPixelSize,
    image_px: PositiveDimsU32,

    /// Computes image and infobar cell geometry plus pixel render dimensions
    /// from terminal `winsize` and `infobar` placement. Falls back to
    /// `termgfx.default_cell_px` when the terminal does not report pixel size.
    pub fn compute(
        winsize: vaxis.Winsize,
        infobar: InfobarPosition,
    ) ViewportLayout {
        const cols: u16 = @max(winsize.cols, 1);
        const rows: u16 = @max(winsize.rows, 1);

        const cell_px: CellPixelSize = if (winsize.cols > 0 and
            winsize.rows > 0 and
            winsize.x_pixel >= winsize.cols and
            winsize.y_pixel >= winsize.rows)
            .{
                .w = winsize.x_pixel / winsize.cols,
                .h = winsize.y_pixel / winsize.rows,
            }
        else
            termgfx.default_cell_px;

        const Band = struct {
            image_row: u16,
            image_rows: u16,
            infobar_row: ?u16,
        };
        const band: Band = if (rows <= 1)
            .{
                .image_row = 0,
                .image_rows = rows,
                .infobar_row = null,
            }
        else switch (infobar) {
            .bottom => .{
                .image_row = 0,
                .image_rows = rows - 1,
                .infobar_row = rows - 1,
            },
            .top => .{
                .image_row = 1,
                .image_rows = rows - 1,
                .infobar_row = 0,
            },
            .none => .{
                .image_row = 0,
                .image_rows = rows,
                .infobar_row = null,
            },
        };

        const px_w: u32 = @max(
            @as(u32, 1),
            @as(u32, cols) * @as(u32, cell_px.w),
        );
        const px_h: u32 = @max(
            @as(u32, 1),
            @as(u32, band.image_rows) * @as(u32, cell_px.h),
        );

        return .{
            .cols = cols,
            .rows = rows,
            .image_row = band.image_row,
            .image_cols = cols,
            .image_rows = band.image_rows,
            .infobar_row = band.infobar_row,
            .cell_px = cell_px,
            .image_px = .{ .w = px_w, .h = px_h },
        };
    }

    /// Returns the uncropped cell rectangle covering the entire image viewport.
    pub fn fullCrop(self: ViewportLayout) ImageCellCrop {
        return .{
            .col_off = 0,
            .row_off = 0,
            .cols = self.image_cols,
            .rows = self.image_rows,
            .px = self.image_px,
        };
    }

    /// Snaps a pixel-space rectangle `rect` (in `[0, image_px]`) outward to
    /// the terminal cell grid, clamped to `[0, image_cols] x [0, image_rows]`.
    /// Falls back to `fullCrop()` when `rect` is non-finite or non-positive.
    pub fn cropForRect(self: ViewportLayout, rect: FRect) ImageCellCrop {
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
            !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or
            rect.w <= 0.0 or rect.h <= 0.0)
        {
            return self.fullCrop();
        }
        const max_px_w: f32 = @floatFromInt(self.image_px.w);
        const max_px_h: f32 = @floatFromInt(self.image_px.h);
        const min_x = std.math.clamp(rect.x, 0.0, max_px_w);
        const max_x = std.math.clamp(rect.x + rect.w, 0.0, max_px_w);
        const min_y = std.math.clamp(rect.y, 0.0, max_px_h);
        const max_y = std.math.clamp(rect.y + rect.h, 0.0, max_px_h);
        if (max_x <= min_x or max_y <= min_y) {
            return self.fullCrop();
        }

        const cw: f32 = @floatFromInt(@max(self.cell_px.w, 1));
        const ch: f32 = @floatFromInt(@max(self.cell_px.h, 1));
        const max_cols_f: f32 = @floatFromInt(self.image_cols);
        const max_rows_f: f32 = @floatFromInt(self.image_rows);

        const col_start_f = std.math.clamp(
            @floor(min_x / cw),
            0.0,
            max_cols_f,
        );
        const col_end_f = std.math.clamp(
            @ceil(max_x / cw),
            0.0,
            max_cols_f,
        );
        const row_start_f = std.math.clamp(
            @floor(min_y / ch),
            0.0,
            max_rows_f,
        );
        const row_end_f = std.math.clamp(
            @ceil(max_y / ch),
            0.0,
            max_rows_f,
        );

        const col_off: u16 = @min(
            self.image_cols -| 1,
            @as(u16, @intFromFloat(col_start_f)),
        );
        const col_end: u16 = @min(
            self.image_cols,
            @max(col_off + 1, @as(u16, @intFromFloat(col_end_f))),
        );
        const row_off: u16 = @min(
            self.image_rows -| 1,
            @as(u16, @intFromFloat(row_start_f)),
        );
        const row_end: u16 = @min(
            self.image_rows,
            @max(row_off + 1, @as(u16, @intFromFloat(row_end_f))),
        );

        const cols = col_end - col_off;
        const rows = row_end - row_off;
        return .{
            .col_off = col_off,
            .row_off = row_off,
            .cols = cols,
            .rows = rows,
            .px = .{
                .w = @max(
                    @as(u32, 1),
                    @as(u32, cols) * @as(u32, self.cell_px.w),
                ),
                .h = @max(
                    @as(u32, 1),
                    @as(u32, rows) * @as(u32, self.cell_px.h),
                ),
            },
        };
    }

    /// Returns a child `vaxis.Window` covering only the image viewport area.
    pub fn imageWindow(self: ViewportLayout, root: vaxis.Window) vaxis.Window {
        return root.child(.{
            .x_off = 0,
            .y_off = self.image_row,
            .width = self.image_cols,
            .height = self.image_rows,
        });
    }

    /// Returns a 1-row child `vaxis.Window` for the infobar, or `null` when
    /// hidden or when the terminal is only 1 row tall.
    pub fn infobarWindow(
        self: ViewportLayout,
        root: vaxis.Window,
    ) ?vaxis.Window {
        const row = self.infobar_row orelse return null;
        return root.child(.{
            .x_off = 0,
            .y_off = row,
            .width = self.cols,
            .height = 1,
        });
    }
};

fn toVaxisColor(color: termgfx.HalfblockColor) vaxis.Color {
    return switch (color) {
        .default => .default,
        .rgb => |c| .{ .rgb = .{ c.r, c.g, c.b } },
    };
}

/// Blits an RGBA8888 image (`rgba_pixels`, `pitch`, `dims`) into `win` using
/// Unicode upper half-blocks (`▀`) backed by `termgfx`'s SIMD box sampler so
/// `vaxis` diffs dirty cells and composites modals cleanly on top of the image.
pub fn blitHalfblocksToWindow(
    win: vaxis.Window,
    rgba_pixels: []const u8,
    pitch: usize,
    dims: PositiveDimsU32,
) void {
    if (win.width == 0 or win.height == 0 or dims.w == 0 or dims.h == 0) {
        return;
    }
    const min_row_bytes = std.math.mul(usize, @as(usize, dims.w), 4) catch
        return;
    if (pitch < min_row_bytes) return;
    const last_row_off = std.math.mul(
        usize,
        @as(usize, dims.h - 1),
        pitch,
    ) catch return;
    const required_bytes = std.math.add(
        usize,
        last_row_off,
        min_row_bytes,
    ) catch return;
    if (rgba_pixels.len < required_bytes) return;

    const cols: u32 = win.width;
    const rows: u32 = win.height;
    const half_rows: u32 = rows * 2;

    var r: u16 = 0;
    while (r < win.height) : (r += 1) {
        const top_idx: u32 = @as(u32, r) * 2;
        const bot_idx: u32 = top_idx + 1;

        var c: u16 = 0;
        while (c < win.width) : (c += 1) {
            const top = toVaxisColor(termgfx.sampleHalfblockBox(
                rgba_pixels,
                pitch,
                dims,
                c,
                cols,
                top_idx,
                half_rows,
            ));
            const bot = toVaxisColor(termgfx.sampleHalfblockBox(
                rgba_pixels,
                pitch,
                dims,
                c,
                cols,
                bot_idx,
                half_rows,
            ));

            win.writeCell(c, r, .{
                .char = .{ .grapheme = upper_half_block, .width = 1 },
                .style = .{ .fg = top, .bg = bot },
            });
        }
    }
}

test "ViewportLayout.cropForRect snaps outward, clamps, handles edge cases" {
    const layout = ViewportLayout.compute(
        .{ .cols = 100, .rows = 40, .x_pixel = 1000, .y_pixel = 800 },
        .bottom,
    );
    // Portrait image centered horizontally: x in [255, 745], full height.
    const crop = layout.cropForRect(.{
        .x = 255.0,
        .y = 0.0,
        .w = 490.0,
        .h = 780.0,
    });
    // floor(255 / 10) = 25, ceil(745 / 10) = 75 -> 50 cols (500px).
    try std.testing.expectEqual(@as(u16, 25), crop.col_off);
    try std.testing.expectEqual(@as(u16, 0), crop.row_off);
    try std.testing.expectEqual(@as(u16, 50), crop.cols);
    try std.testing.expectEqual(@as(u16, 39), crop.rows);
    try std.testing.expectEqual(@as(u32, 500), crop.px.w);
    try std.testing.expectEqual(@as(u32, 780), crop.px.h);
    try std.testing.expectEqual(
        @as(f32, 250.0),
        crop.pxOffsetX(layout.cell_px),
    );
    try std.testing.expectEqual(
        @as(f32, 0.0),
        crop.pxOffsetY(layout.cell_px),
    );

    // Rect larger than viewport clamps to fullCrop.
    const oversized = layout.cropForRect(.{
        .x = -50.0,
        .y = -20.0,
        .w = 1200.0,
        .h = 900.0,
    });
    try std.testing.expect(oversized.eql(layout.fullCrop()));

    // Non-finite or empty rects safely fall back to fullCrop.
    try std.testing.expect(layout.cropForRect(.{
        .x = std.math.nan(f32),
        .y = 0.0,
        .w = 100.0,
        .h = 100.0,
    }).eql(layout.fullCrop()));
    try std.testing.expect(layout.cropForRect(.{
        .x = 0.0,
        .y = 0.0,
        .w = 0.0,
        .h = 100.0,
    }).eql(layout.fullCrop()));
}

test "InfobarPosition.next cycles bottom -> top -> none -> bottom" {
    try std.testing.expectEqual(
        InfobarPosition.top,
        InfobarPosition.bottom.next(),
    );
    try std.testing.expectEqual(
        InfobarPosition.none,
        InfobarPosition.top.next(),
    );
    try std.testing.expectEqual(
        InfobarPosition.bottom,
        InfobarPosition.none.next(),
    );
}

test "ViewportLayout computes bottom, top, none, child windows, and clamps" {
    const ws = vaxis.Winsize{
        .cols = 100,
        .rows = 40,
        .x_pixel = 1000,
        .y_pixel = 800,
    };

    const bottom = ViewportLayout.compute(ws, .bottom);
    try std.testing.expectEqual(@as(u16, 0), bottom.image_row);
    try std.testing.expectEqual(@as(u16, 39), bottom.image_rows);
    try std.testing.expectEqual(@as(?u16, 39), bottom.infobar_row);
    try std.testing.expectEqual(@as(u16, 10), bottom.cell_px.w);
    try std.testing.expectEqual(@as(u16, 20), bottom.cell_px.h);
    try std.testing.expectEqual(@as(u32, 1000), bottom.image_px.w);
    try std.testing.expectEqual(@as(u32, 780), bottom.image_px.h);

    const top = ViewportLayout.compute(ws, .top);
    try std.testing.expectEqual(@as(u16, 1), top.image_row);
    try std.testing.expectEqual(@as(u16, 39), top.image_rows);
    try std.testing.expectEqual(@as(?u16, 0), top.infobar_row);

    const none = ViewportLayout.compute(ws, .none);
    try std.testing.expectEqual(@as(u16, 0), none.image_row);
    try std.testing.expectEqual(@as(u16, 40), none.image_rows);
    try std.testing.expectEqual(@as(?u16, null), none.infobar_row);

    // Zero pixel metrics and 0x0 winsize clamp safely.
    const zero_ws = ViewportLayout.compute(
        .{ .cols = 0, .rows = 0, .x_pixel = 0, .y_pixel = 0 },
        .bottom,
    );
    try std.testing.expectEqual(@as(u16, 1), zero_ws.cols);
    try std.testing.expectEqual(@as(u16, 1), zero_ws.rows);
    try std.testing.expectEqual(@as(?u16, null), zero_ws.infobar_row);
    try std.testing.expectEqual(termgfx.default_cell_px, zero_ws.cell_px);

    // Verify imageWindow and infobarWindow child bounds.
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, ws);
    defer screen.deinit(allocator);
    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = ws.cols,
        .height = ws.rows,
        .screen = &screen,
    };

    const top_img = top.imageWindow(root);
    try std.testing.expectEqual(@as(i17, 1), top_img.y_off);
    try std.testing.expectEqual(@as(u16, 39), top_img.height);
    const top_bar = top.infobarWindow(root).?;
    try std.testing.expectEqual(@as(i17, 0), top_bar.y_off);
    try std.testing.expectEqual(@as(u16, 1), top_bar.height);
    try std.testing.expect(none.infobarWindow(root) == null);
}

test "blitHalfblocksToWindow handles exact, padded, scaled, and invalid" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 2,
        .rows = 1,
        .x_pixel = 16,
        .y_pixel = 16,
    });
    defer screen.deinit(allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 2,
        .height = 1,
        .screen = &screen,
    };

    // Invalid inputs return safely without panicking or writing.
    blitHalfblocksToWindow(win, &.{}, 0, .{ .w = 0, .h = 0 });
    blitHalfblocksToWindow(win, &.{}, 4, .{ .w = 2, .h = 2 });
    blitHalfblocksToWindow(
        win,
        &.{ 0, 0, 0, 0 },
        std.math.maxInt(usize),
        .{ .w = 2, .h = 2 },
    );

    // 2x2 RGBA image with padded pitch (12 bytes/row instead of 8).
    const padded = [_]u8{
        255, 0, 0,   255, 0, 255, 0, 255, 99, 99, 99, 99,
        0,   0, 255, 255, 0, 0,   0, 0,   99, 99, 99, 99,
    };
    blitHalfblocksToWindow(win, &padded, 12, .{ .w = 2, .h = 2 });

    const left_cell = win.readCell(0, 0).?;
    try std.testing.expectEqualStrings(
        upper_half_block,
        left_cell.char.grapheme,
    );
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 255, 0, 0 } },
        left_cell.style.fg,
    );
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 0, 0, 255 } },
        left_cell.style.bg,
    );

    const right_cell = win.readCell(1, 0).?;
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 0, 255, 0 } },
        right_cell.style.fg,
    );
    try std.testing.expectEqual(vaxis.Color.default, right_cell.style.bg);

    // Upscaling 1x1 solid gray onto 2x1 window fills both cells cleanly.
    const one_px = [_]u8{ 100, 150, 200, 255 };
    blitHalfblocksToWindow(win, &one_px, 4, .{ .w = 1, .h = 1 });
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 100, 150, 200 } },
        win.readCell(1, 0).?.style.fg,
    );
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 100, 150, 200 } },
        win.readCell(1, 0).?.style.bg,
    );

    // Downscaling 4x2 (top-left pair avg(0, 200)=100) into 2x1 window.
    const down = [_]u8{
        0, 0,   0, 255, 200, 0,   0, 255, 0, 0, 0, 255, 0, 0, 0, 255,
        0, 100, 0, 255, 0,   200, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255,
    };
    blitHalfblocksToWindow(win, &down, 16, .{ .w = 4, .h = 2 });
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 100, 0, 0 } },
        win.readCell(0, 0).?.style.fg,
    );
    try std.testing.expectEqual(
        vaxis.Color{ .rgb = .{ 0, 150, 0 } },
        win.readCell(0, 0).?.style.bg,
    );
}
