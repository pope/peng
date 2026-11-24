const std = @import("std");

/// Concrete terminal graphics protocol backend.
pub const Protocol = enum {
    kitty,
    sixel,
};

/// User-facing protocol selection mode (`auto` resolves from environment).
pub const ProtocolMode = enum {
    auto,
    kitty,
    sixel,

    /// Parses a case-insensitive CLI protocol mode string.
    pub fn parse(raw: []const u8) ?ProtocolMode {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(raw, "sixel")) return .sixel;
        return null;
    }

    /// Resolves this mode into a concrete `Protocol` using `environ_map`
    /// when set to `.auto`.
    pub fn resolve(
        self: ProtocolMode,
        environ_map: *const std.process.Environ.Map,
    ) Protocol {
        return switch (self) {
            .auto => detectProtocolFromEnviron(environ_map),
            .kitty => .kitty,
            .sixel => .sixel,
        };
    }
};

/// Comma-separated list of valid `--protocol` values for CLI help/errors.
pub const protocol_modes_string = "auto, kitty, sixel";

/// Snapshot of terminal-identifying environment variables used for pure,
/// zero-I/O protocol detection.
const TerminalEnv = struct {
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    kitty_window_id: ?[]const u8 = null,
    ghostty_resources_dir: ?[]const u8 = null,
    wezterm_executable: ?[]const u8 = null,
    wezterm_pane: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
};

fn isNonEmpty(val: ?[]const u8) bool {
    return if (val) |s| s.len > 0 else false;
}

/// Detects the preferred terminal graphics `Protocol` from `env` using
/// zero-latency environment heuristics (no TTY raw-mode probing).
///
/// Routing rules:
/// - Inside `tmux`: `.sixel` (native Sixel avoids Kitty passthrough issues).
/// - Kitty & Ghostty: `.kitty`.
/// - WezTerm, Foot, mlterm, mintty, Contour, Rio, VSCode, BlackBox, yaft:
///   `.sixel`.
/// - Unknown / stripped environment: `.kitty` fallback.
fn detectProtocol(env: TerminalEnv) Protocol {
    if (isNonEmpty(env.tmux)) return .sixel;

    if (env.term_program) |tp| {
        if (std.ascii.eqlIgnoreCase(tp, "kitty") or
            std.ascii.eqlIgnoreCase(tp, "ghostty"))
        {
            return .kitty;
        }
        const sixel_programs = [_][]const u8{
            "wezterm",
            "foot",
            "mlterm",
            "mintty",
            "contour",
            "rio",
            "vscode",
            "blackbox",
        };
        for (sixel_programs) |name| {
            if (std.ascii.eqlIgnoreCase(tp, name)) return .sixel;
        }
    }

    if (isNonEmpty(env.kitty_window_id) or
        isNonEmpty(env.ghostty_resources_dir))
    {
        return .kitty;
    }

    if (isNonEmpty(env.wezterm_executable) or isNonEmpty(env.wezterm_pane)) {
        return .sixel;
    }

    if (env.term) |term| {
        if (std.mem.eql(u8, term, "xterm-kitty") or
            std.mem.eql(u8, term, "xterm-ghostty"))
        {
            return .kitty;
        }
        if (std.mem.startsWith(u8, term, "foot") or
            std.mem.startsWith(u8, term, "mlterm") or
            std.mem.startsWith(u8, term, "yaft"))
        {
            return .sixel;
        }
    }

    return .kitty;
}

fn detectProtocolFromEnviron(
    environ_map: *const std.process.Environ.Map,
) Protocol {
    return detectProtocol(.{
        .term = environ_map.get("TERM"),
        .term_program = environ_map.get("TERM_PROGRAM"),
        .kitty_window_id = environ_map.get("KITTY_WINDOW_ID"),
        .ghostty_resources_dir = environ_map.get("GHOSTTY_RESOURCES_DIR"),
        .wezterm_executable = environ_map.get("WEZTERM_EXECUTABLE"),
        .wezterm_pane = environ_map.get("WEZTERM_PANE"),
        .tmux = environ_map.get("TMUX"),
    });
}

test "detectProtocol routes Kitty and Ghostty to kitty" {
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{ .kitty_window_id = "1" }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{ .ghostty_resources_dir = "/usr/share/ghostty" }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{ .term = "xterm-ghostty" }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{ .term_program = "ghostty" }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{ .term = "xterm-kitty" }),
    );
}

test "detectProtocol routes WezTerm, foot, and tmux to sixel" {
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{ .term_program = "WezTerm" }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{ .wezterm_pane = "0" }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{ .term = "foot-extra" }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .kitty_window_id = "1",
        }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{
            .term_program = "WezTerm",
            .ghostty_resources_dir = "/usr/share/ghostty",
        }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{}),
    );
}

test "ProtocolMode.parse handles valid and invalid names" {
    try std.testing.expectEqual(ProtocolMode.auto, ProtocolMode.parse("auto"));
    try std.testing.expectEqual(
        ProtocolMode.kitty,
        ProtocolMode.parse("KITTY"),
    );
    try std.testing.expectEqual(
        ProtocolMode.sixel,
        ProtocolMode.parse("Sixel"),
    );
    try std.testing.expectEqual(null, ProtocolMode.parse("iterm2"));
}
