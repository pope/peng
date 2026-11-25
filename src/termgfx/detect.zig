const builtin = @import("builtin");
const geom = @import("geom");
const std = @import("std");

const PositiveDimsU32 = geom.PositiveDimsU32;

/// Concrete terminal graphics protocol backend.
pub const Protocol = enum {
    kitty,
    sixel,
    iterm2,
    halfblocks,
};

/// Terminal cell dimensions (columns x rows), e.g. from `--cells COLSxROWS`.
pub const CellDims = struct {
    cols: u32,
    rows: u32,
};

/// Pixel dimensions of a single terminal character cell (`w` x `h` pixels).
pub const CellPixelSize = struct {
    w: u32,
    h: u32,
};

/// Conservative fallback cell pixel dimensions used when `TIOCGWINSZ` is
/// unavailable or reports zero pixel extents (e.g. headless pipes or older
/// multiplexers).
pub const default_cell_px: CellPixelSize = .{ .w = 10, .h = 20 };

/// Converts terminal `cells` into a clamped maximum pixel bounding box
/// (`[1, 4096]`) using `cell_px`.
pub fn cellsToPixels(
    cells: CellDims,
    cell_px: CellPixelSize,
) PositiveDimsU32 {
    const cw: u64 = @max(1, cell_px.w);
    const ch: u64 = @max(1, cell_px.h);
    const px_w: u64 = @as(u64, @max(1, cells.cols)) * cw;
    const px_h: u64 = @as(u64, @max(1, cells.rows)) * ch;
    return .{
        .w = @intCast(@min(px_w, 4096)),
        .h = @intCast(@min(px_h, 4096)),
    };
}

fn cellPixelSizeFromWinsize(
    col: u16,
    row: u16,
    xpixel: u16,
    ypixel: u16,
) ?CellPixelSize {
    if (col == 0 or row == 0 or xpixel == 0 or ypixel == 0) {
        return null;
    }
    const c: u32 = col;
    const r: u32 = row;
    const cw: u32 = @max(1, (@as(u32, xpixel) + c / 2) / c);
    const ch: u32 = @max(1, (@as(u32, ypixel) + r / 2) / r);
    return .{ .w = cw, .h = ch };
}

fn queryWinsizeFd(fd: std.posix.fd_t) ?CellPixelSize {
    var ws: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    while (true) {
        const rc = std.posix.system.ioctl(
            fd,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        }
    }
    return cellPixelSizeFromWinsize(ws.col, ws.row, ws.xpixel, ws.ypixel);
}

/// Queries the active terminal's per-cell pixel dimensions via POSIX
/// `ioctl(TIOCGWINSZ)` on `stdout`, `stderr`, or `/dev/tty`. Returns `null`
/// on Windows or when no TTY reports non-zero pixel dimensions.
pub fn queryCellPixelSize(io: std.Io) ?CellPixelSize {
    if (builtin.os.tag == .windows) return null;
    if (queryWinsizeFd(std.posix.STDOUT_FILENO)) |px| return px;
    if (queryWinsizeFd(std.posix.STDERR_FILENO)) |px| return px;
    const tty = std.Io.Dir.cwd().openFile(io, "/dev/tty", .{}) catch {
        return null;
    };
    defer tty.close(io);
    return queryWinsizeFd(tty.handle);
}

/// Escape-sequence framing mode for the active terminal / multiplexer.
pub const TransportMode = enum {
    direct,
    tmux_passthrough,
    tmux_unicode_placeholders,
};

/// Resolved terminal graphics backend and transport framing mode.
pub const ResolvedTarget = struct {
    protocol: Protocol,
    transport: TransportMode = .direct,
};

/// User-facing protocol selection mode (`auto` resolves from environment).
pub const ProtocolMode = enum {
    auto,
    kitty,
    sixel,
    iterm2,
    halfblocks,

    /// Parses a case-insensitive CLI protocol mode string.
    pub fn parse(raw: []const u8) ?ProtocolMode {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(raw, "sixel")) return .sixel;
        if (std.ascii.eqlIgnoreCase(raw, "iterm2")) return .iterm2;
        if (std.ascii.eqlIgnoreCase(raw, "halfblocks") or
            std.ascii.eqlIgnoreCase(raw, "halfblock"))
        {
            return .halfblocks;
        }
        return null;
    }

    /// Resolves this mode into a concrete `ResolvedTarget` (protocol and
    /// `TransportMode`) using `environ_map`.
    pub fn resolve(
        self: ProtocolMode,
        environ_map: *const std.process.Environ.Map,
    ) ResolvedTarget {
        const env = terminalEnvFromEnviron(environ_map);
        const protocol: Protocol = switch (self) {
            .auto => detectProtocol(env),
            .kitty => .kitty,
            .sixel => .sixel,
            .iterm2 => .iterm2,
            .halfblocks => .halfblocks,
        };
        return .{
            .protocol = protocol,
            .transport = resolveTransport(env, protocol),
        };
    }
};

/// Comma-separated list of valid `--protocol` values for CLI help/errors.
pub const protocol_modes_string = "auto, kitty, sixel, iterm2, halfblocks";

/// Snapshot of terminal-identifying environment variables used for pure,
/// zero-I/O protocol detection.
const TerminalEnv = struct {
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    kitty_window_id: ?[]const u8 = null,
    ghostty_resources_dir: ?[]const u8 = null,
    iterm_session_id: ?[]const u8 = null,
    wezterm_executable: ?[]const u8 = null,
    wezterm_pane: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
};

fn isNonEmpty(val: ?[]const u8) bool {
    return if (val) |s| s.len > 0 else false;
}

/// Resolves the `TransportMode` for `protocol` in `env`:
/// - Outside `tmux`: `.direct`.
/// - Inside `tmux`: `.tmux_unicode_placeholders` for Kitty (`U=1`),
///   `.tmux_passthrough` for iTerm2, and `.direct` for native `tmux` Sixel and
///   Unicode half-blocks.
fn resolveTransport(env: TerminalEnv, protocol: Protocol) TransportMode {
    if (!isNonEmpty(env.tmux)) return .direct;
    return switch (protocol) {
        .kitty => .tmux_unicode_placeholders,
        .iterm2 => .tmux_passthrough,
        .sixel, .halfblocks => .direct,
    };
}

/// Detects the preferred terminal graphics `Protocol` from `env` using
/// zero-latency environment heuristics (no TTY raw-mode probing).
///
/// Routing rules:
/// - Kitty & Ghostty: `.kitty` (uses `U=1` Unicode placeholders in `tmux`).
/// - WezTerm: `.iterm2` outside `tmux` (24-bit truecolor); `.sixel` inside
///   `tmux` (native `tmux` cell-grid rendering with clean cursor/exit).
/// - iTerm2, Warp, Tabby, Hyper: `.iterm2`.
/// - Foot, mlterm, mintty, Contour, Rio, VSCode, BlackBox, yaft: `.sixel`.
/// - Unknown outer terminal inside `tmux`: `.sixel`; otherwise `.kitty`.
fn detectProtocol(env: TerminalEnv) Protocol {
    const in_tmux = isNonEmpty(env.tmux);

    if (env.term_program) |tp| {
        if (std.ascii.eqlIgnoreCase(tp, "kitty") or
            std.ascii.eqlIgnoreCase(tp, "ghostty"))
        {
            return .kitty;
        }
        if (std.ascii.eqlIgnoreCase(tp, "wezterm")) {
            return if (in_tmux) .sixel else .iterm2;
        }
        const iterm2_programs = [_][]const u8{
            "iterm.app",
            "warpterminal",
            "tabby",
            "hyper",
        };
        for (iterm2_programs) |name| {
            if (std.ascii.eqlIgnoreCase(tp, name)) return .iterm2;
        }
        const sixel_programs = [_][]const u8{
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
        return if (in_tmux) .sixel else .iterm2;
    }

    if (isNonEmpty(env.iterm_session_id)) {
        return .iterm2;
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

    if (in_tmux) return .sixel;
    return .kitty;
}

fn terminalEnvFromEnviron(
    environ_map: *const std.process.Environ.Map,
) TerminalEnv {
    return .{
        .term = environ_map.get("TERM"),
        .term_program = environ_map.get("TERM_PROGRAM"),
        .kitty_window_id = environ_map.get("KITTY_WINDOW_ID"),
        .ghostty_resources_dir = environ_map.get("GHOSTTY_RESOURCES_DIR"),
        .iterm_session_id = environ_map.get("ITERM_SESSION_ID"),
        .wezterm_executable = environ_map.get("WEZTERM_EXECUTABLE"),
        .wezterm_pane = environ_map.get("WEZTERM_PANE"),
        .tmux = environ_map.get("TMUX"),
    };
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

test "detectProtocol routes WezTerm and iTerm2 to iterm2, foot/tmux to sixel" {
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{ .term_program = "WezTerm" }),
    );
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{ .wezterm_pane = "0" }),
    );
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{ .term_program = "iTerm.app" }),
    );
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{ .iterm_session_id = "w0t0p0:ABC" }),
    );
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{
            .term_program = "WezTerm",
            .ghostty_resources_dir = "/usr/share/ghostty",
        }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{ .term = "foot-extra" }),
    );
    // Inside tmux: detect outer terminal rather than forcing sixel.
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .term_program = "ghostty",
        }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .term_program = "tmux",
            .kitty_window_id = "1",
        }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .term_program = "WezTerm",
        }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .term_program = "tmux",
            .wezterm_pane = "0",
        }),
    );
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
            .term = "tmux-256color",
        }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{}),
    );
}

test "resolveTransport selects direct, passthrough, or U=1 placeholders" {
    try std.testing.expectEqual(
        TransportMode.direct,
        resolveTransport(.{}, .kitty),
    );
    try std.testing.expectEqual(
        TransportMode.tmux_unicode_placeholders,
        resolveTransport(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
        }, .kitty),
    );
    try std.testing.expectEqual(
        TransportMode.tmux_passthrough,
        resolveTransport(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
        }, .iterm2),
    );
    try std.testing.expectEqual(
        TransportMode.direct,
        resolveTransport(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
        }, .sixel),
    );
    try std.testing.expectEqual(
        TransportMode.direct,
        resolveTransport(.{
            .tmux = "/tmp/tmux-1000/default,123,0",
        }, .halfblocks),
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
    try std.testing.expectEqual(
        ProtocolMode.iterm2,
        ProtocolMode.parse("iTerm2"),
    );
    try std.testing.expectEqual(
        ProtocolMode.halfblocks,
        ProtocolMode.parse("halfblocks"),
    );
    try std.testing.expectEqual(
        ProtocolMode.halfblocks,
        ProtocolMode.parse("HalfBlock"),
    );
    try std.testing.expectEqual(null, ProtocolMode.parse("unknown"));
}

test "cellsToPixels scales cells by pixel size and clamps to 4096" {
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 600, .h = 600 },
        cellsToPixels(.{ .cols = 60, .rows = 30 }, .{ .w = 10, .h = 20 }),
    );
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 1280, .h = 960 },
        cellsToPixels(.{ .cols = 80, .rows = 30 }, .{ .w = 16, .h = 32 }),
    );
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 4096, .h = 4096 },
        cellsToPixels(.{ .cols = 500, .rows = 500 }, .{ .w = 20, .h = 40 }),
    );
    // Rounds nearest cell pixel dimensions instead of truncating toward zero.
    try std.testing.expectEqual(
        CellPixelSize{ .w = 10, .h = 20 },
        cellPixelSizeFromWinsize(192, 54, 1910, 1070).?,
    );
    try std.testing.expectEqual(
        @as(?CellPixelSize, null),
        cellPixelSizeFromWinsize(80, 24, 0, 0),
    );
}
