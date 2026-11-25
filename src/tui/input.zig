//! Terminal Input Adapter (`libvaxis` -> Peng `state.FrameInput`)
//!
//! Pure, zero-SDL translation layer converting `vaxis.Key` and `vaxis.Mouse`
//! events into Peng's `FrameInput` and TUI-local actions so `peng-tui` shares
//! Peng's full keybinding, palette, and motion pipeline.

const intents = @import("intents");
const state = @import("state");
const std = @import("std");
const vaxis = @import("vaxis");

const FrameInput = state.FrameInput;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const QuitRequest = state.QuitRequest;

comptime {
    std.debug.assert(
        @backingInt(Key.char_z) - @backingInt(Key.char_a) == 25,
    );
}

/// Scroll wheel step in logical units per terminal wheel tick, matching Peng's
/// `MOUSE_WHEEL_SCROLL_MULTIPLIER` cadence.
pub const wheel_scroll_step: f32 = 6.0;

/// Mapped Peng key and normalized modifier state for a single `vaxis.Key`.
pub const MappedKey = struct {
    key: Key,
    mods: KeyModifiers,
};

/// TUI-specific local actions intercepted before forwarding to Peng's
/// `FrameInput` (for keys whose GUI meaning does not apply in a terminal).
pub const TuiLocalActions = struct {
    cycle_infobar: bool = false,
    open_file_search: bool = false,
};

/// Maps `vaxis.Key.Modifiers` to Peng's `intents.KeyModifiers`.
pub fn mapModifiers(mods: vaxis.Key.Modifiers) KeyModifiers {
    return .{
        .ctrl = mods.ctrl,
        .shift = mods.shift,
        .alt = mods.alt,
        .gui = mods.super or mods.meta,
    };
}

/// Maps `vaxis.Mouse.Modifiers` to Peng's `intents.KeyModifiers`.
pub fn mapMouseModifiers(mods: vaxis.Mouse.Modifiers) KeyModifiers {
    return .{
        .ctrl = mods.ctrl,
        .shift = mods.shift,
        .alt = mods.alt,
        .gui = false,
    };
}

const CodepointMapping = struct {
    key: Key,
    implies_shift: bool = false,
    clears_shift: bool = false,
};

fn mapCodepoint(cp: u21) ?CodepointMapping {
    const KeyTag = @typeInfo(Key).@"enum".tag_type;
    return switch (cp) {
        vaxis.Key.escape => .{ .key = .escape },
        vaxis.Key.enter, vaxis.Key.kp_enter => .{ .key = .return_key },
        vaxis.Key.backspace => .{ .key = .backspace },
        vaxis.Key.tab => .{ .key = .tab },
        vaxis.Key.space => .{ .key = .space },
        vaxis.Key.left, vaxis.Key.kp_left => .{ .key = .left },
        vaxis.Key.right, vaxis.Key.kp_right => .{ .key = .right },
        vaxis.Key.up, vaxis.Key.kp_up => .{ .key = .up },
        vaxis.Key.down, vaxis.Key.kp_down => .{ .key = .down },
        vaxis.Key.home, vaxis.Key.kp_home => .{ .key = .home },
        vaxis.Key.end, vaxis.Key.kp_end => .{ .key = .end },
        vaxis.Key.page_up, vaxis.Key.kp_page_up => .{ .key = .page_up },
        vaxis.Key.page_down, vaxis.Key.kp_page_down => .{ .key = .page_down },
        vaxis.Key.f1 => .{ .key = .f1 },
        vaxis.Key.f5 => .{ .key = .f5 },
        vaxis.Key.f11 => .{ .key = .f11 },
        '=', vaxis.Key.kp_equal, vaxis.Key.kp_add => .{ .key = .equals },
        '+' => .{ .key = .equals, .clears_shift = true },
        '-', vaxis.Key.kp_subtract => .{ .key = .minus },
        '[' => .{ .key = .left_bracket },
        ']' => .{ .key = .right_bracket },
        ':' => .{ .key = .colon, .clears_shift = true },
        ';' => .{ .key = .semicolon },
        '/', vaxis.Key.kp_divide => .{ .key = .slash },
        '?' => .{ .key = .question, .clears_shift = true },
        '.', vaxis.Key.kp_decimal => .{ .key = .period },
        ',' => .{ .key = .comma },
        '<' => .{ .key = .less, .clears_shift = true },
        '>' => .{ .key = .greater, .clears_shift = true },
        '\\' => .{ .key = .backslash },
        '0', vaxis.Key.kp_0 => .{ .key = .char_0 },
        '1', vaxis.Key.kp_1 => .{ .key = .char_1 },
        '2', vaxis.Key.kp_2 => .{ .key = .char_2 },
        '3', vaxis.Key.kp_3 => .{ .key = .char_3 },
        '4', vaxis.Key.kp_4 => .{ .key = .char_4 },
        '5', vaxis.Key.kp_5 => .{ .key = .char_5 },
        '6', vaxis.Key.kp_6 => .{ .key = .char_6 },
        '7', vaxis.Key.kp_7 => .{ .key = .char_7 },
        '8', vaxis.Key.kp_8 => .{ .key = .char_8 },
        '9', vaxis.Key.kp_9 => .{ .key = .char_9 },
        'a'...'z' => .{
            .key = @fromBackingInt(
                @backingInt(Key.char_a) + @as(KeyTag, @intCast(cp - 'a')),
            ),
        },
        'A'...'Z' => .{
            .key = @fromBackingInt(
                @backingInt(Key.char_a) + @as(KeyTag, @intCast(cp - 'A')),
            ),
            .implies_shift = true,
        },
        else => null,
    };
}

fn applyCodepointMapping(
    mapping: CodepointMapping,
    base_mods: KeyModifiers,
) MappedKey {
    var mods = base_mods;
    if (mapping.clears_shift) {
        mods.shift = false;
    } else if (mapping.implies_shift) {
        mods.shift = true;
    }
    return .{ .key = mapping.key, .mods = mods };
}

/// Translates a `vaxis.Key` into a normalized Peng `Key` and `KeyModifiers`.
/// Unifies legacy VT shifted characters (`'E'`, `':'`, `'?'`, `'<'`, `'>'`)
/// with Kitty CSI-u base+shifted key reports (`codepoint=';'`,
/// `shifted_codepoint=':'`, `mods.shift=true`).
pub fn mapKey(key: vaxis.Key) MappedKey {
    if (key.isModifier()) {
        return .{ .key = .unknown, .mods = .{} };
    }

    const mods = mapModifiers(key.mods);

    // When Kitty CSI-u reports a shifted punctuation symbol that has its own
    // dedicated `intents.Key` variant (`:`, `?`, `<`, `>`, `+`), resolve to
    // that key with shift cleared so Peng's unshifted symbol shortcuts match.
    if (key.mods.shift) {
        if (key.shifted_codepoint) |scp| {
            if (mapCodepoint(scp)) |mapping| {
                if (mapping.clears_shift) {
                    return applyCodepointMapping(mapping, mods);
                }
            }
        }
    }

    if (mapCodepoint(key.codepoint)) |mapping| {
        return applyCodepointMapping(mapping, mods);
    }

    if (key.base_layout_codepoint) |base_cp| {
        if (mapCodepoint(base_cp)) |mapping| {
            return applyCodepointMapping(mapping, mods);
        }
    }

    return .{ .key = .unknown, .mods = mods };
}

/// Per-frame accumulator collecting `vaxis` keyboard and mouse events into
/// Peng's `FrameInput` and TUI-local action flags.
pub const InputAccumulator = struct {
    frame_allocator: std.mem.Allocator,
    keys_pressed: std.ArrayList(Key) = .empty,
    key_modifiers: KeyModifiers = .{},
    text_buf: std.ArrayList(u8) = .empty,
    quit_request: QuitRequest = .none,
    local_actions: TuiLocalActions = .{},
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_left_down: bool = false,
    mouse_left_clicked: bool = false,
    mouse_inside: bool = false,
    scroll_delta_x: f32 = 0.0,
    scroll_delta_y: f32 = 0.0,

    /// Initializes a fresh per-frame accumulator backed by `frame_allocator`.
    pub fn init(
        frame_allocator: std.mem.Allocator,
        mouse_left_down: bool,
        mouse_x: f32,
        mouse_y: f32,
    ) InputAccumulator {
        return .{
            .frame_allocator = frame_allocator,
            .mouse_left_down = mouse_left_down,
            .mouse_x = mouse_x,
            .mouse_y = mouse_y,
        };
    }

    /// Releases dynamic lists allocated with `frame_allocator`.
    pub fn deinit(self: *InputAccumulator) void {
        self.keys_pressed.deinit(self.frame_allocator);
        self.text_buf.deinit(self.frame_allocator);
    }

    /// Consumes a `vaxis.Key` press event. When `text_capture_active` is
    /// `true` (palette or parameter prompt open), printable text is appended
    /// to `text_buf` and TUI-local single-letter overrides (`f`, `V`) are
    /// bypassed so typing works normally.
    pub fn handleKeyPress(
        self: *InputAccumulator,
        key: vaxis.Key,
        text_capture_active: bool,
    ) !void {
        if (key.isModifier()) return;

        const mapped = mapKey(key);

        // Ctrl+C always triggers clean termination (including non-Latin
        // layouts resolved via `base_layout_codepoint`).
        if (mapped.key == .char_c and mapped.mods.eql(.{ .ctrl = true })) {
            self.quit_request = .terminate;
            return;
        }

        if (!text_capture_active and !mapped.mods.ctrl and !mapped.mods.alt and
            !mapped.mods.gui)
        {
            // `f` is GUI Fullscreen in Peng; in peng-tui it opens File Search.
            if (mapped.key == .char_f and !mapped.mods.shift) {
                self.local_actions.open_file_search = true;
                return;
            }
            // `V` cycles infobar placement (bottom -> top -> none).
            if (mapped.key == .char_v and mapped.mods.shift) {
                self.local_actions.cycle_infobar = true;
                return;
            }
        }

        if (mapped.key != .unknown) {
            try self.keys_pressed.append(self.frame_allocator, mapped.key);
            self.key_modifiers = mapped.mods;
        }

        if (text_capture_active and !mapped.mods.ctrl and !mapped.mods.alt and
            !mapped.mods.gui)
        {
            try self.appendPrintableText(key);
        }
    }

    fn appendPrintableText(self: *InputAccumulator, key: vaxis.Key) !void {
        if (key.text) |txt| {
            for (txt) |b| {
                if (b >= 0x20 and b != 0x7F) {
                    try self.text_buf.append(self.frame_allocator, b);
                }
            }
            return;
        }
        // Fallback for terminals/tests that populate `codepoint` without
        // setting `text`.
        var cp = if (key.mods.shift)
            (key.shifted_codepoint orelse key.codepoint)
        else
            key.codepoint;
        if (key.mods.shift and key.shifted_codepoint == null and
            cp >= 'a' and cp <= 'z')
        {
            cp = std.ascii.toUpper(@intCast(cp));
        }
        if (cp >= 0x20 and cp < 0x7F) {
            try self.text_buf.append(self.frame_allocator, @intCast(cp));
        }
    }

    /// Consumes a `vaxis.Mouse` event, mapping terminal cell coordinates into
    /// viewport pixel coordinates using `cell_w_px` and `cell_h_px`.
    pub fn handleMouse(
        self: *InputAccumulator,
        mouse: vaxis.Mouse,
        cell_w_px: f32,
        cell_h_px: f32,
    ) void {
        const col_f: f32 = @floatFromInt(@max(mouse.col, 0));
        const row_f: f32 = @floatFromInt(@max(mouse.row, 0));
        const xoff_f: f32 = @floatFromInt(mouse.xoffset);
        const yoff_f: f32 = @floatFromInt(mouse.yoffset);
        self.mouse_x = col_f * cell_w_px + xoff_f;
        self.mouse_y = row_f * cell_h_px + yoff_f;
        self.mouse_inside = true;

        if (self.keys_pressed.items.len == 0) {
            self.key_modifiers = mapMouseModifiers(mouse.mods);
        }

        switch (mouse.button) {
            .wheel_up => self.scroll_delta_y += wheel_scroll_step,
            .wheel_down => self.scroll_delta_y -= wheel_scroll_step,
            .wheel_left => self.scroll_delta_x += wheel_scroll_step,
            .wheel_right => self.scroll_delta_x -= wheel_scroll_step,
            .left => switch (mouse.type) {
                .press => {
                    self.mouse_left_down = true;
                    self.mouse_left_clicked = true;
                },
                .release => {
                    self.mouse_left_down = false;
                },
                .drag => {
                    self.mouse_left_down = true;
                },
                .motion => {},
            },
            .none => switch (mouse.type) {
                // Legacy xterm mouse mode reports button release as `.none`.
                .release => self.mouse_left_down = false,
                .press, .motion, .drag => {},
            },
            .middle,
            .right,
            .button_8,
            .button_9,
            .button_10,
            .button_11,
            => {},
        }
    }

    /// Builds a `state.FrameInput` snapshot for `app.systems.runUpdatePhase`.
    /// The returned `FrameInput` borrows `keys_pressed` and `text_input` from
    /// `self`; `self` must outlive the returned `FrameInput` and its caller
    /// releases backing storage via `self.deinit()`.
    pub fn toFrameInput(
        self: *const InputAccumulator,
        win_w: f32,
        win_h: f32,
        delta_time_ms: f32,
        now_ms: u64,
    ) FrameInput {
        const text_opt: ?[]const u8 = if (self.text_buf.items.len > 0)
            self.text_buf.items
        else
            null;
        return .{
            .win_w = win_w,
            .win_h = win_h,
            .scale_x = 1.0,
            .scale_y = 1.0,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_left_down = self.mouse_left_down,
            .mouse_left_clicked = self.mouse_left_clicked,
            .mouse_inside = self.mouse_inside,
            .quit_request = self.quit_request,
            .scroll_delta_x = self.scroll_delta_x,
            .scroll_delta_y = self.scroll_delta_y,
            .keys_pressed = self.keys_pressed,
            .key_modifiers = self.key_modifiers,
            .text_input = text_opt,
            .dropped_path = null,
            .delta_time_ms = delta_time_ms,
            .now_ms = now_ms,
        };
    }
};

test "mapKey unifies legacy VT, Kitty CSI-u, and base_layout_codepoint" {
    // Kitty CSI-u Shift+; -> :
    const kitty_colon = mapKey(.{
        .codepoint = ';',
        .shifted_codepoint = ':',
        .mods = .{ .shift = true },
        .text = ":",
    });
    try std.testing.expectEqual(Key.colon, kitty_colon.key);
    try std.testing.expect(!kitty_colon.mods.shift);

    // Direct ':' with shift flag and no shifted_codepoint clears shift.
    const shifted_colon = mapKey(.{
        .codepoint = ':',
        .mods = .{ .shift = true },
        .text = ":",
    });
    try std.testing.expectEqual(Key.colon, shifted_colon.key);
    try std.testing.expect(!shifted_colon.mods.shift);

    // Legacy VT ':' directly
    const vt_colon = mapKey(.{
        .codepoint = ':',
        .text = ":",
    });
    try std.testing.expectEqual(Key.colon, vt_colon.key);
    try std.testing.expect(!vt_colon.mods.shift);

    // Kitty CSI-u Shift+/ -> ?
    const kitty_q = mapKey(.{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .mods = .{ .shift = true },
        .text = "?",
    });
    try std.testing.expectEqual(Key.question, kitty_q.key);
    try std.testing.expect(!kitty_q.mods.shift);

    // Legacy VT uppercase 'E' -> char_e + shift
    const vt_upper = mapKey(.{ .codepoint = 'E', .text = "E" });
    try std.testing.expectEqual(Key.char_e, vt_upper.key);
    try std.testing.expect(vt_upper.mods.shift);

    // Kitty CSI-u lowercase 'e' + shift -> char_e + shift
    const kitty_upper = mapKey(.{
        .codepoint = 'e',
        .shifted_codepoint = 'E',
        .mods = .{ .shift = true },
        .text = "E",
    });
    try std.testing.expectEqual(Key.char_e, kitty_upper.key);
    try std.testing.expect(kitty_upper.mods.shift);

    // Non-Latin layout falls back to base_layout_codepoint.
    const cyrillic_n = mapKey(.{
        .codepoint = 0x0442,
        .base_layout_codepoint = 'n',
    });
    try std.testing.expectEqual(Key.char_n, cyrillic_n.key);

    // Pure modifier press is ignored.
    const mod_only = mapKey(.{ .codepoint = vaxis.Key.left_shift });
    try std.testing.expectEqual(Key.unknown, mod_only.key);
}

test "InputAccumulator intercepts Ctrl+C, f, and V in viewer mode" {
    const allocator = std.testing.allocator;
    var acc = InputAccumulator.init(allocator, false, 0.0, 0.0);
    defer acc.deinit();

    // `f` triggers local open_file_search instead of fullscreen.
    try acc.handleKeyPress(.{ .codepoint = 'f', .text = "f" }, false);
    try std.testing.expect(acc.local_actions.open_file_search);
    try std.testing.expectEqual(@as(usize, 0), acc.keys_pressed.items.len);

    // `V` triggers local cycle_infobar.
    try acc.handleKeyPress(.{
        .codepoint = 'v',
        .shifted_codepoint = 'V',
        .mods = .{ .shift = true },
        .text = "V",
    }, false);
    try std.testing.expect(acc.local_actions.cycle_infobar);
    try std.testing.expectEqual(@as(usize, 0), acc.keys_pressed.items.len);

    // `n` forwards normally to Peng.
    try acc.handleKeyPress(.{ .codepoint = 'n', .text = "n" }, false);
    try std.testing.expectEqual(@as(usize, 1), acc.keys_pressed.items.len);
    try std.testing.expectEqual(Key.char_n, acc.keys_pressed.items[0]);

    // `Ctrl+C` (including via base_layout_codepoint) sets .terminate.
    try acc.handleKeyPress(.{
        .codepoint = 0x0441,
        .base_layout_codepoint = 'c',
        .mods = .{ .ctrl = true },
    }, false);
    try std.testing.expectEqual(QuitRequest.terminate, acc.quit_request);
}

test "InputAccumulator captures text in palette mode and filters control keys" {
    const allocator = std.testing.allocator;
    var acc = InputAccumulator.init(allocator, false, 0.0, 0.0);
    defer acc.deinit();

    // `f` and `V` type normally when palette is active.
    try acc.handleKeyPress(.{ .codepoint = 'f', .text = "f" }, true);
    try acc.handleKeyPress(.{
        .codepoint = 'v',
        .mods = .{ .shift = true },
    }, true);
    // Control keys (Enter, Backspace, Tab) do not append control bytes.
    try acc.handleKeyPress(
        .{ .codepoint = vaxis.Key.enter, .text = "\r" },
        true,
    );
    try acc.handleKeyPress(
        .{ .codepoint = vaxis.Key.backspace, .text = "\x7f" },
        true,
    );
    try acc.handleKeyPress(.{ .codepoint = vaxis.Key.tab, .text = "\t" }, true);

    try std.testing.expect(!acc.local_actions.open_file_search);
    try std.testing.expect(!acc.local_actions.cycle_infobar);

    const frame = acc.toFrameInput(800.0, 600.0, 16.0, 100);
    try std.testing.expectEqualStrings("fV", frame.text_input.?);
    try std.testing.expectEqual(@as(usize, 5), frame.keys_pressed.items.len);
}

test "InputAccumulator translates mouse wheel, Ctrl+wheel, and xterm release" {
    const allocator = std.testing.allocator;
    var acc = InputAccumulator.init(allocator, false, 0.0, 0.0);
    defer acc.deinit();

    acc.handleMouse(.{
        .col = 10,
        .row = 5,
        .xoffset = 2,
        .yoffset = 4,
        .button = .wheel_up,
        .mods = .{ .ctrl = true },
        .type = .press,
    }, 8.0, 16.0);

    try std.testing.expectEqual(@as(f32, 82.0), acc.mouse_x);
    try std.testing.expectEqual(@as(f32, 84.0), acc.mouse_y);
    try std.testing.expectEqual(wheel_scroll_step, acc.scroll_delta_y);
    try std.testing.expect(acc.key_modifiers.ctrl);
    try std.testing.expect(acc.mouse_inside);

    // Horizontal scroll matches Peng's traditional scroll direction.
    acc.handleMouse(.{
        .col = 10,
        .row = 5,
        .button = .wheel_right,
        .mods = .{},
        .type = .press,
    }, 8.0, 16.0);
    try std.testing.expectEqual(-wheel_scroll_step, acc.scroll_delta_x);

    // Left press then legacy xterm `.none` release clears mouse_left_down.
    acc.handleMouse(.{
        .col = 12,
        .row = 6,
        .button = .left,
        .mods = .{},
        .type = .press,
    }, 8.0, 16.0);
    try std.testing.expect(acc.mouse_left_down);
    try std.testing.expect(acc.mouse_left_clicked);

    acc.handleMouse(.{
        .col = 14,
        .row = 6,
        .button = .none,
        .mods = .{},
        .type = .release,
    }, 8.0, 16.0);
    try std.testing.expect(!acc.mouse_left_down);
}
