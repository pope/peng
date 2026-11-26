//! Interactive Terminal Overlays (Palette, Prompts, and Image Details)
//!
//! Pure, zero-SDL modal renderers backed by Peng's existing `PaletteState`,
//! `NavigationState`, and image metadata, drawn into centered `vaxis.Window`
//! borders that composite over `z_index = -1` Kitty images and Halfblocks.

const infobar = @import("infobar.zig");
const intents = @import("intents");
const palette = @import("palette");
const std = @import("std");
const triage = @import("triage");
const vaxis = @import("vaxis");
const vfs = @import("vfs");

const ActivePaletteMode = intents.ActivePaletteMode;
const Classification = triage.Classification;
const DirectoryEntry = vfs.DirectoryEntry;
const MediaEntry = vfs.MediaEntry;
const palette_action_items = intents.actions.palette_action_items;
const PaletteState = palette.PaletteState;

const bg_modal: vaxis.Color = .{ .rgb = .{ 24, 24, 37 } };
const bg_selected: vaxis.Color = .{ .rgb = .{ 49, 50, 68 } };
const fg_border: vaxis.Color = .{ .rgb = .{ 108, 112, 134 } };
const fg_text: vaxis.Color = .{ .rgb = .{ 205, 214, 244 } };
const fg_subtext: vaxis.Color = .{ .rgb = .{ 166, 173, 200 } };
const fg_blue: vaxis.Color = .{ .rgb = .{ 137, 180, 250 } };
const fg_pink: vaxis.Color = .{ .rgb = .{ 245, 194, 231 } };
const fg_mauve: vaxis.Color = .{ .rgb = .{ 203, 166, 247 } };
const fg_peach: vaxis.Color = .{ .rgb = .{ 250, 179, 135 } };
const fg_green: vaxis.Color = .{ .rgb = .{ 166, 227, 161 } };
const fg_red: vaxis.Color = .{ .rgb = .{ 243, 139, 168 } };
const fg_yellow: vaxis.Color = .{ .rgb = .{ 249, 226, 175 } };

/// Snapshot of current image metadata displayed in the `d` Details modal.
pub const DetailsModel = struct {
    filename: []const u8 = "",
    source_path: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    file_size_bytes: ?u64 = null,
    classification: Classification = .unflagged,
    zoom_pct: u32 = 100,
    rotation_deg: i32 = 0,
    filter_name: []const u8 = "",
};

fn modeAccent(mode: ActivePaletteMode) vaxis.Color {
    return switch (mode) {
        .files => fg_pink,
        .actions => fg_blue,
        .directory_navigator => fg_mauve,
        .prompt => |kind| switch (kind) {
            .edit_param => fg_peach,
            .go_to_image => fg_green,
            .slideshow_interval => fg_yellow,
        },
    };
}

fn writeClippedRow(
    win: vaxis.Window,
    row: u16,
    start_col: u16,
    max_cols: u16,
    text: []const u8,
    style: vaxis.Style,
) u16 {
    if (row >= win.height or start_col >= win.width or max_cols == 0 or
        text.len == 0)
    {
        return 0;
    }
    const avail = @min(max_cols, win.width - start_col);
    var col: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const slice = grapheme.bytes(text);
        const w_raw = win.gwidth(slice);
        if (w_raw == 0) continue;
        const w: u16 = @intCast(@min(w_raw, std.math.maxInt(u16)));
        if (col +| w > avail) break;
        win.writeCell(start_col + col, row, .{
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

fn fillRow(win: vaxis.Window, row: u16, bg: vaxis.Color) void {
    if (row >= win.height) return;
    var c: u16 = 0;
    while (c < win.width) : (c += 1) {
        win.writeCell(c, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .fg = fg_text, .bg = bg },
        });
    }
}

fn createCenteredModal(
    parent: vaxis.Window,
    desired_w: u16,
    desired_h: u16,
    border_color: vaxis.Color,
) ?vaxis.Window {
    if (parent.width < 12 or parent.height < 5) return null;
    const w = @min(desired_w, parent.width -| 2);
    const h = @min(desired_h, parent.height -| 2);
    if (w < 10 or h < 5) return null;

    const x_off = (parent.width -| w) / 2;
    const y_off = (parent.height -| h) / 2;

    // `child(.{ .border = .{ .where = .all } })` already returns the interior
    // window inset by 1 cell on all four sides.
    const inner = parent.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = .{ .fg = border_color, .bg = bg_modal },
        },
    });
    inner.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .fg = fg_text, .bg = bg_modal },
    });
    return inner;
}

fn formatByteSize(
    allocator: std.mem.Allocator,
    bytes: u64,
) []const u8 {
    if (bytes >= 1024 * 1024) {
        const mb: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return allocator.print("{d:.2} MiB", .{mb}) catch "";
    }
    if (bytes >= 1024) {
        const kb: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return allocator.print("{d:.1} KiB", .{kb}) catch "";
    }
    return allocator.print("{d} B", .{bytes}) catch "";
}

fn dirEntryLabel(
    allocator: std.mem.Allocator,
    entry: DirectoryEntry,
) []const u8 {
    return switch (entry) {
        .parent => |p| infobar.sanitizeUtf8(allocator, p.name),
        .directory => |d| blk: {
            const clean = infobar.sanitizeUtf8(allocator, d.name);
            break :blk allocator.print("[DIR] {s}/", .{clean}) catch clean;
        },
        .archive_file => |a| blk: {
            const clean = infobar.sanitizeUtf8(allocator, a.name);
            break :blk allocator.print("[ZIP] {s}", .{clean}) catch clean;
        },
        .image_file => |f| infobar.sanitizeUtf8(allocator, f.name),
    };
}

/// Renders the active Command Palette, File Search, Directory Navigator, or
/// Parameter Prompt modal centered inside `parent`. Formatted strings are
/// allocated from `frame_allocator`, which must outlive `vaxis.render`.
pub fn renderPalette(
    parent: vaxis.Window,
    pal: *const PaletteState,
    media_entries: []const MediaEntry,
    classifications: []const Classification,
    frame_allocator: std.mem.Allocator,
) void {
    const mode = pal.visibleMode() orelse return;
    const cfg = palette.getPaletteConfig(mode);
    const accent = modeAccent(mode);

    const is_prompt = switch (mode) {
        .prompt => true,
        .files, .actions, .directory_navigator => false,
    };

    const desired_w: u16 = if (is_prompt) 56 else 72;
    const desired_h: u16 = if (is_prompt) 6 else 18;
    const inner = createCenteredModal(
        parent,
        desired_w,
        desired_h,
        accent,
    ) orelse return;

    // Row 0: Header title + right-aligned match count without overlap.
    const total = pal.matches.items.len;
    const count_str: []const u8 = if (!is_prompt and total > 0)
        frame_allocator.print(
            "{d}/{d}",
            .{ @min(pal.selected_idx +| 1, total), total },
        ) catch ""
    else
        "";
    const cw: u16 = @intCast(
        @min(inner.gwidth(count_str), std.math.maxInt(u16)),
    );
    const show_count = count_str.len > 0 and cw +| 4 < inner.width;
    const title_max = if (show_count)
        inner.width -| (cw +| 3)
    else
        inner.width -| 2;

    _ = writeClippedRow(inner, 0, 1, title_max, cfg.title, .{
        .fg = accent,
        .bg = bg_modal,
        .bold = true,
    });
    if (show_count) {
        _ = writeClippedRow(
            inner,
            0,
            inner.width -| (cw +| 1),
            cw,
            count_str,
            .{ .fg = fg_subtext, .bg = bg_modal },
        );
    }

    // Row 1: Query input line (`> query_`).
    if (inner.height > 1) {
        const clean_q = infobar.sanitizeUtf8(frame_allocator, pal.query.items);
        const prompt_line = if (clean_q.len > 0)
            frame_allocator.print("> {s}_", .{clean_q}) catch "> _"
        else
            frame_allocator.print("> {s}", .{cfg.placeholder}) catch "> ";
        _ = writeClippedRow(inner, 1, 1, inner.width -| 2, prompt_line, .{
            .fg = if (clean_q.len > 0) fg_text else fg_subtext,
            .bg = bg_modal,
        });
    }

    if (is_prompt) {
        if (inner.height > 3) {
            _ = writeClippedRow(
                inner,
                3,
                1,
                inner.width -| 2,
                "Enter: apply   Esc: cancel",
                .{ .fg = fg_subtext, .bg = bg_modal },
            );
        }
        return;
    }

    // Row 2: Subtle horizontal divider.
    if (inner.height > 2) {
        var c: u16 = 0;
        while (c < inner.width) : (c += 1) {
            inner.writeCell(c, 2, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = fg_border, .bg = bg_modal },
            });
        }
    }

    // Rows 3..height: Scrollable match list.
    if (inner.height <= 3) return;
    const visible_rows: usize = inner.height - 3;
    if (total == 0) {
        _ = writeClippedRow(
            inner,
            3,
            1,
            inner.width -| 2,
            "No matching items",
            .{ .fg = fg_subtext, .bg = bg_modal },
        );
        return;
    }

    const selected = @min(pal.selected_idx, total - 1);
    const start_idx: usize = if (selected >= visible_rows)
        selected - visible_rows + 1
    else
        0;
    const end_idx = @min(total, start_idx + visible_rows);

    for (start_idx..end_idx, 0..) |match_pos, row_off| {
        const row: u16 = @intCast(3 + row_off);
        const is_sel = (match_pos == selected);
        const row_bg = if (is_sel) bg_selected else bg_modal;
        const row_fg = if (is_sel) accent else fg_text;
        if (is_sel) fillRow(inner, row, bg_selected);

        const raw_idx = pal.matches.items[match_pos];
        const prefix: []const u8 = if (is_sel) "> " else "  ";
        _ = writeClippedRow(inner, row, 0, 2, prefix, .{
            .fg = accent,
            .bg = row_bg,
            .bold = is_sel,
        });

        switch (mode) {
            .actions => {
                if (raw_idx < palette_action_items.len) {
                    const item = palette_action_items[raw_idx];
                    const hint = item.shortcut_text;
                    const hint_w: u16 = @intCast(
                        @min(inner.gwidth(hint), std.math.maxInt(u16)),
                    );
                    const show_hint = hint.len > 0 and
                        hint_w +| 8 < inner.width;
                    const name_max = if (show_hint)
                        inner.width -| (hint_w +| 4)
                    else
                        inner.width -| 3;
                    _ = writeClippedRow(inner, row, 2, name_max, item.name, .{
                        .fg = row_fg,
                        .bg = row_bg,
                        .bold = is_sel,
                    });
                    if (show_hint) {
                        _ = writeClippedRow(
                            inner,
                            row,
                            inner.width -| (hint_w +| 1),
                            hint_w,
                            hint,
                            .{ .fg = fg_subtext, .bg = row_bg },
                        );
                    }
                }
            },
            .files => {
                if (raw_idx < media_entries.len) {
                    const cls: Classification =
                        if (raw_idx < classifications.len)
                            classifications[raw_idx]
                        else
                            .unflagged;
                    const badge: []const u8 = switch (cls) {
                        .pick => "* ",
                        .reject => "x ",
                        .unflagged => "  ",
                    };
                    const badge_fg: vaxis.Color = switch (cls) {
                        .pick => fg_green,
                        .reject => fg_red,
                        .unflagged => fg_subtext,
                    };
                    _ = writeClippedRow(inner, row, 2, 2, badge, .{
                        .fg = badge_fg,
                        .bg = row_bg,
                        .bold = true,
                    });
                    const name = infobar.sanitizeUtf8(
                        frame_allocator,
                        media_entries[raw_idx].getBasename(),
                    );
                    _ = writeClippedRow(
                        inner,
                        row,
                        4,
                        inner.width -| 5,
                        name,
                        .{ .fg = row_fg, .bg = row_bg, .bold = is_sel },
                    );
                }
            },
            .directory_navigator => {
                if (raw_idx < pal.dir_items.items.len) {
                    const label = dirEntryLabel(
                        frame_allocator,
                        pal.dir_items.items[raw_idx],
                    );
                    _ = writeClippedRow(
                        inner,
                        row,
                        2,
                        inner.width -| 3,
                        label,
                        .{ .fg = row_fg, .bg = row_bg, .bold = is_sel },
                    );
                }
            },
            .prompt => unreachable,
        }
    }
}

/// Renders the `d` Image Details modal centered inside `parent`. Formatted
/// strings are allocated from `frame_allocator`, which must outlive
/// `vaxis.render`.
pub fn renderDetails(
    parent: vaxis.Window,
    model: DetailsModel,
    frame_allocator: std.mem.Allocator,
) void {
    const inner = createCenteredModal(parent, 64, 12, fg_blue) orelse return;

    _ = writeClippedRow(inner, 0, 1, inner.width -| 2, "Image Details", .{
        .fg = fg_blue,
        .bg = bg_modal,
        .bold = true,
    });

    const dims_str = if (model.width > 0 and model.height > 0)
        frame_allocator.print("{d} x {d} px", .{
            model.width,
            model.height,
        }) catch "-"
    else
        "-";
    const size_str = if (model.file_size_bytes) |b|
        formatByteSize(frame_allocator, b)
    else
        "-";
    const zoom_str = frame_allocator.print(
        "{d}% ({s})",
        .{ model.zoom_pct, model.filter_name },
    ) catch "";
    const rot_str = frame_allocator.print("{d} deg", .{
        model.rotation_deg,
    }) catch "0 deg";

    const Row = struct { label: []const u8, value: []const u8 };
    const rows = [_]Row{
        .{
            .label = "File",
            .value = infobar.sanitizeUtf8(frame_allocator, model.filename),
        },
        .{
            .label = "Path",
            .value = infobar.sanitizeUtf8(frame_allocator, model.source_path),
        },
        .{ .label = "Dimensions", .value = dims_str },
        .{ .label = "File Size", .value = size_str },
        .{ .label = "Triage", .value = model.classification.label() },
        .{ .label = "Zoom", .value = zoom_str },
        .{ .label = "Rotation", .value = rot_str },
    };

    const label_w: u16 = 12;
    for (rows, 0..) |item, i| {
        const r: u16 = @intCast(2 + i);
        if (r >= inner.height) break;
        _ = writeClippedRow(inner, r, 1, label_w, item.label, .{
            .fg = fg_subtext,
            .bg = bg_modal,
        });
        if (inner.width > label_w +| 3) {
            _ = writeClippedRow(
                inner,
                r,
                label_w +| 2,
                inner.width -| (label_w +| 3),
                item.value,
                .{ .fg = fg_text, .bg = bg_modal },
            );
        }
    }
}

fn screenContains(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    needle: []const u8,
) !bool {
    var r: u16 = 0;
    while (r < win.height) : (r += 1) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        var c: u16 = 0;
        while (c < win.width) {
            const cell = win.readCell(c, r).?;
            try line.appendSlice(allocator, cell.char.grapheme);
            c += @max(@as(u16, 1), @as(u16, cell.char.width));
        }
        if (std.mem.find(u8, line.items, needle) != null) return true;
    }
    return false;
}

test "renderPalette draws Command Palette modal and selected action" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 90,
        .rows = 24,
        .x_pixel = 900,
        .y_pixel = 480,
    });
    defer screen.deinit(allocator);

    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 90,
        .height = 24,
        .screen = &screen,
    };

    var pal = try PaletteState.init(allocator);
    defer pal.deinit(allocator);
    pal.lifecycle = .{ .open = .actions };
    try pal.matches.append(allocator, 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    renderPalette(root, &pal, &.{}, &.{}, arena.allocator());

    try std.testing.expect(try screenContains(
        allocator,
        root,
        "Command Palette",
    ));
    try std.testing.expect(try screenContains(
        allocator,
        root,
        palette_action_items[0].name,
    ));
}

test "renderDetails renders metadata and handles narrow screens safely" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = 70,
        .rows = 18,
        .x_pixel = 700,
        .y_pixel = 360,
    });
    defer screen.deinit(allocator);

    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 70,
        .height = 18,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    renderDetails(root, .{
        .filename = "sunset.jpg",
        .source_path = "/photos/sunset.jpg",
        .width = 4000,
        .height = 3000,
        .file_size_bytes = 2 * 1024 * 1024,
        .classification = .pick,
        .zoom_pct = 125,
        .rotation_deg = 90,
        .filter_name = "Lanczos3",
    }, arena.allocator());

    try std.testing.expect(try screenContains(
        allocator,
        root,
        "Image Details",
    ));
    try std.testing.expect(try screenContains(allocator, root, "4000 x 3000"));
    try std.testing.expect(try screenContains(allocator, root, "2.00 MiB"));
    try std.testing.expect(try screenContains(allocator, root, "Pick"));

    // Tiny screen (10x4) returns safely without drawing; narrow (18x6) clips.
    var tiny_screen = try vaxis.Screen.init(allocator, .{
        .cols = 10,
        .rows = 4,
        .x_pixel = 100,
        .y_pixel = 80,
    });
    defer tiny_screen.deinit(allocator);
    const tiny_win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 4,
        .screen = &tiny_screen,
    };
    renderDetails(
        tiny_win,
        .{ .filename = "\x1b\xffbad.jpg" },
        arena.allocator(),
    );

    var narrow_screen = try vaxis.Screen.init(allocator, .{
        .cols = 18,
        .rows = 6,
        .x_pixel = 180,
        .y_pixel = 120,
    });
    defer narrow_screen.deinit(allocator);
    const narrow_win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 18,
        .height = 6,
        .screen = &narrow_screen,
    };
    renderDetails(
        narrow_win,
        .{ .filename = "\x1b\xffbad.jpg" },
        arena.allocator(),
    );
    try std.testing.expect(!try screenContains(allocator, narrow_win, "\x1b"));
}
