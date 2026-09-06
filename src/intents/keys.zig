//! Keyboard Key, Modifier, and Shortcut Definitions
//!
//! Agnostic input definitions that map physical keystrokes and modifier combinations
//! without depending on SDL, Clay, or state subsystems.

const std = @import("std");

/// Normalized keyboard key enumeration covering standard navigation, function, and alphanumeric keys.
pub const Key = enum {
    unknown,
    escape,
    return_key,
    backspace,
    tab,
    space,
    left,
    right,
    up,
    down,
    equals,
    minus,
    left_bracket,
    right_bracket,
    home,
    end,
    page_up,
    page_down,
    f1,
    f11,
    char_0,
    char_1,
    char_2,
    char_3,
    char_4,
    char_5,
    char_6,
    char_7,
    char_8,
    char_9,
    char_a,
    char_b,
    char_c,
    char_d,
    char_e,
    char_f,
    char_g,
    char_h,
    char_i,
    char_j,
    char_k,
    char_l,
    char_m,
    char_n,
    char_o,
    char_p,
    char_q,
    char_r,
    char_s,
    char_t,
    char_u,
    char_v,
    char_w,
    char_x,
    char_y,
    char_z,
};

/// Active keyboard modifier key state mask (Ctrl, Shift, Alt, GUI/Cmd).
pub const KeyModifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    gui: bool = false,

    /// Checks two modifier sets for identical flag settings.
    pub fn eql(self: KeyModifiers, other: KeyModifiers) bool {
        return self.ctrl == other.ctrl and
            self.shift == other.shift and
            self.alt == other.alt and
            self.gui == other.gui;
    }
};

/// Single keyboard key and modifier combination bound to an application action.
pub const KeyboardShortcut = struct {
    key: Key,
    mod: KeyModifiers = .{},
};

test "KeyModifiers equality" {
    const mod1 = KeyModifiers{ .ctrl = true };
    const mod2 = KeyModifiers{ .ctrl = true };
    const mod3 = KeyModifiers{ .shift = true };

    try std.testing.expect(mod1.eql(mod2));
    try std.testing.expect(!mod1.eql(mod3));
}
