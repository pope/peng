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

/// Pixel data transfer medium preference for the Kitty Graphics Protocol.
pub const KittyTransferMode = enum {
    auto,
    shm,
    temp_file,
    direct,
    direct_rgba,
};

/// Resolved terminal graphics backend, transport framing mode, Kitty transfer
/// medium preference, and whether the session is running over SSH
/// (`is_remote`).
pub const ResolvedTarget = struct {
    protocol: Protocol,
    transport: TransportMode = .direct,
    kitty_transfer: KittyTransferMode = .auto,
    is_remote: bool = false,

    /// Reconciles an `.auto`-detected `.direct` Kitty target with a runtime
    /// Kitty graphics capability probe (`has_kitty`). Downgrades unsupported
    /// `.kitty` guesses to `.halfblocks`, while preserving explicit protocol
    /// overrides, `tmux` transports, and non-Kitty protocols.
    pub fn reconcileKittyCapability(
        self: ResolvedTarget,
        mode: ProtocolMode,
        has_kitty: bool,
    ) ResolvedTarget {
        switch (mode) {
            .auto => {},
            .kitty,
            .kitty_shm,
            .kitty_temp,
            .kitty_direct,
            .kitty_rgba,
            .sixel,
            .iterm2,
            .halfblocks,
            => return self,
        }
        switch (self.transport) {
            .direct => {},
            .tmux_passthrough, .tmux_unicode_placeholders => return self,
        }
        var next = self;
        next.protocol = switch (self.protocol) {
            .kitty => if (has_kitty) .kitty else .halfblocks,
            .sixel => .sixel,
            .iterm2 => .iterm2,
            .halfblocks => .halfblocks,
        };
        return next;
    }

    /// Returns a human-readable error message when an explicit Kitty transfer
    /// medium cannot be used in this environment (e.g. `kitty-shm` on Windows,
    /// or local `kitty-shm`/`kitty-temp` over SSH), or `null` when valid.
    pub fn unsupportedKittyReason(self: ResolvedTarget) ?[]const u8 {
        switch (self.protocol) {
            .kitty => {},
            .sixel, .iterm2, .halfblocks => return null,
        }
        return switch (self.kitty_transfer) {
            .auto, .direct, .direct_rgba => null,
            .shm => if (comptime builtin.os.tag == .windows)
                "Kitty shared memory (kitty-shm) is not supported on Windows."
            else if (self.is_remote)
                "Local Kitty transfer (kitty-shm) is not supported over " ++
                    "SSH; use kitty-direct or kitty-rgba."
            else
                null,
            .temp_file => if (self.is_remote)
                "Local Kitty transfer (kitty-temp) is not supported over " ++
                    "SSH; use kitty-direct or kitty-rgba."
            else
                null,
        };
    }
};

/// Requested preview sizing specification covering every valid combination of
/// explicit pixel dimensions (`--size`) and terminal cell grid (`--cells`).
pub const PreviewSize = union(enum) {
    default,
    pixels: PositiveDimsU32,
    cells: CellDims,
    pixels_and_cells: struct {
        pixels: PositiveDimsU32,
        cells: CellDims,
    },

    /// Default pixel bounding box when neither `--size` nor `--cells` is given.
    pub const default_pixels: PositiveDimsU32 = .{ .w = 800, .h = 600 };

    /// Combines an explicit pixel bounding box (`--size`) with this spec,
    /// preserving any previously specified cell grid (`--cells`).
    pub fn withPixels(self: PreviewSize, dims: PositiveDimsU32) PreviewSize {
        return switch (self) {
            .default, .pixels => .{ .pixels = dims },
            .cells => |c| .{
                .pixels_and_cells = .{
                    .pixels = dims,
                    .cells = c,
                },
            },
            .pixels_and_cells => |pc| .{
                .pixels_and_cells = .{
                    .pixels = dims,
                    .cells = pc.cells,
                },
            },
        };
    }

    /// Combines a terminal cell grid (`--cells`) with this spec, preserving
    /// any previously specified explicit pixel dimensions (`--size`).
    pub fn withCells(self: PreviewSize, c: CellDims) PreviewSize {
        return switch (self) {
            .default, .cells => .{ .cells = c },
            .pixels => |p| .{
                .pixels_and_cells = .{
                    .pixels = p,
                    .cells = c,
                },
            },
            .pixels_and_cells => |pc| .{
                .pixels_and_cells = .{
                    .pixels = pc.pixels,
                    .cells = c,
                },
            },
        };
    }

    /// Returns `true` if an explicit pixel bounding box (`--size`) was set.
    pub fn hasExplicitPixels(self: PreviewSize) bool {
        return switch (self) {
            .default, .cells => false,
            .pixels, .pixels_and_cells => true,
        };
    }

    /// Returns the explicit terminal cell grid (`--cells`) if present.
    pub fn cellDims(self: PreviewSize) ?CellDims {
        return switch (self) {
            .default, .pixels => null,
            .cells => |c| c,
            .pixels_and_cells => |pc| pc.cells,
        };
    }

    /// Returns `true` if resolving pixel dimensions or emitting to `target`
    /// (`null` for `--output` file mode) requires querying `TIOCGWINSZ` cell
    /// pixel dimensions.
    pub fn needsCellPixelSize(
        self: PreviewSize,
        target: ?ResolvedTarget,
    ) bool {
        const needs_for_decode = switch (self) {
            .cells => true,
            .default, .pixels, .pixels_and_cells => false,
        };
        if (needs_for_decode) return true;
        const t = target orelse return false;
        return switch (t.protocol) {
            .halfblocks => true,
            .kitty => switch (t.transport) {
                .tmux_unicode_placeholders => true,
                .direct, .tmux_passthrough => false,
            },
            .sixel, .iterm2 => false,
        };
    }

    /// Resolves the maximum decode/render pixel bounding box using `cell_px`
    /// (falling back to `default_cell_px` when `null`).
    pub fn resolveMaxPixels(
        self: PreviewSize,
        cell_px: ?CellPixelSize,
    ) PositiveDimsU32 {
        return switch (self) {
            .default => default_pixels,
            .pixels => |p| p,
            .cells => |c| cellsToPixels(c, cell_px orelse default_cell_px),
            .pixels_and_cells => |pc| pc.pixels,
        };
    }
};

/// User-facing protocol selection mode (`auto` resolves from environment).
pub const ProtocolMode = enum {
    auto,
    kitty,
    kitty_shm,
    kitty_temp,
    kitty_direct,
    kitty_rgba,
    sixel,
    iterm2,
    halfblocks,

    /// Parses a case-insensitive CLI protocol mode string.
    pub fn parse(raw: []const u8) ?ProtocolMode {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(raw, "kitty-shm")) return .kitty_shm;
        if (std.ascii.eqlIgnoreCase(raw, "kitty-temp")) return .kitty_temp;
        if (std.ascii.eqlIgnoreCase(raw, "kitty-direct")) return .kitty_direct;
        if (std.ascii.eqlIgnoreCase(raw, "kitty-rgba")) return .kitty_rgba;
        if (std.ascii.eqlIgnoreCase(raw, "sixel")) return .sixel;
        if (std.ascii.eqlIgnoreCase(raw, "iterm2")) return .iterm2;
        if (std.ascii.eqlIgnoreCase(raw, "halfblocks") or
            std.ascii.eqlIgnoreCase(raw, "halfblock"))
        {
            return .halfblocks;
        }
        return null;
    }

    /// Resolves this mode into a concrete `ResolvedTarget` (protocol,
    /// `TransportMode`, and `KittyTransferMode`) using `environ_map`.
    pub fn resolve(
        self: ProtocolMode,
        environ_map: *const std.process.Environ.Map,
    ) ResolvedTarget {
        const env = terminalEnvFromEnviron(environ_map);
        const protocol: Protocol = switch (self) {
            .auto => detectProtocol(env),
            .kitty,
            .kitty_shm,
            .kitty_temp,
            .kitty_direct,
            .kitty_rgba,
            => .kitty,
            .sixel => .sixel,
            .iterm2 => .iterm2,
            .halfblocks => .halfblocks,
        };
        const kitty_transfer: KittyTransferMode = switch (self) {
            .auto, .kitty, .sixel, .iterm2, .halfblocks => .auto,
            .kitty_shm => .shm,
            .kitty_temp => .temp_file,
            .kitty_direct => .direct,
            .kitty_rgba => .direct_rgba,
        };
        return .{
            .protocol = protocol,
            .transport = resolveTransport(env, protocol),
            .kitty_transfer = kitty_transfer,
            .is_remote = isRemoteSession(env),
        };
    }
};

/// Comma-separated list of valid `--protocol` values for CLI help/errors
/// (omits `kitty-shm` on Windows where POSIX shared memory is unsupported).
pub const protocol_modes_string = if (builtin.os.tag == .windows)
    "auto, kitty, kitty-temp, kitty-direct, kitty-rgba, " ++
        "sixel, iterm2, halfblocks"
else
    "auto, kitty, kitty-shm, kitty-temp, kitty-direct, " ++
        "kitty-rgba, sixel, iterm2, halfblocks";

const remote_protocol_modes_string =
    "auto, kitty, kitty-direct, kitty-rgba, sixel, iterm2, halfblocks";

/// Returns the comma-separated `--protocol` modes valid for the active
/// session (`environ_map`), omitting local-only `kitty-shm` and `kitty-temp`
/// over SSH (and `kitty-shm` on Windows).
pub fn protocolModesString(
    environ_map: *const std.process.Environ.Map,
) []const u8 {
    if (isRemoteSession(terminalEnvFromEnviron(environ_map))) {
        return remote_protocol_modes_string;
    }
    return protocol_modes_string;
}

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
    wt_session: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
    ssh_connection: ?[]const u8 = null,
    ssh_tty: ?[]const u8 = null,
    ssh_client: ?[]const u8 = null,
};

fn isNonEmpty(val: ?[]const u8) bool {
    return if (val) |s| s.len > 0 else false;
}

fn isRemoteSession(env: TerminalEnv) bool {
    return isNonEmpty(env.ssh_connection) or
        isNonEmpty(env.ssh_tty) or
        isNonEmpty(env.ssh_client);
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
/// - Foot, mlterm, mintty, Contour, Rio, VSCode, BlackBox, yaft, Windows
///   Terminal (`WT_SESSION`): `.sixel`.
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

    if (isNonEmpty(env.wt_session)) return .sixel;
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
        .wt_session = environ_map.get("WT_SESSION"),
        .tmux = environ_map.get("TMUX"),
        .ssh_connection = environ_map.get("SSH_CONNECTION"),
        .ssh_tty = environ_map.get("SSH_TTY"),
        .ssh_client = environ_map.get("SSH_CLIENT"),
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
        ProtocolMode.kitty_shm,
        ProtocolMode.parse("kitty-shm"),
    );
    try std.testing.expectEqual(
        ProtocolMode.kitty_temp,
        ProtocolMode.parse("Kitty-Temp"),
    );
    try std.testing.expectEqual(
        ProtocolMode.kitty_direct,
        ProtocolMode.parse("kitty-direct"),
    );
    try std.testing.expectEqual(
        ProtocolMode.kitty_rgba,
        ProtocolMode.parse("KITTY-RGBA"),
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

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(
        KittyTransferMode.shm,
        ProtocolMode.kitty_shm.resolve(&env).kitty_transfer,
    );
    try std.testing.expectEqual(
        KittyTransferMode.temp_file,
        ProtocolMode.kitty_temp.resolve(&env).kitty_transfer,
    );
    try std.testing.expectEqual(
        KittyTransferMode.direct,
        ProtocolMode.kitty_direct.resolve(&env).kitty_transfer,
    );
    try std.testing.expectEqual(
        KittyTransferMode.direct_rgba,
        ProtocolMode.kitty_rgba.resolve(&env).kitty_transfer,
    );
    try std.testing.expectEqual(
        KittyTransferMode.auto,
        ProtocolMode.kitty.resolve(&env).kitty_transfer,
    );
    try std.testing.expectEqualStrings(
        protocol_modes_string,
        protocolModesString(&env),
    );
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(
            ProtocolMode.kitty_shm.resolve(&env).unsupportedKittyReason() !=
                null,
        );
    } else {
        try std.testing.expectEqual(
            @as(?[]const u8, null),
            ProtocolMode.kitty_shm.resolve(&env).unsupportedKittyReason(),
        );
    }
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        ProtocolMode.kitty_temp.resolve(&env).unsupportedKittyReason(),
    );

    // Over SSH, local-only kitty-shm and kitty-temp are rejected and omitted
    // from help text, while kitty-direct and kitty-rgba remain valid.
    try env.put("SSH_CONNECTION", "1.2.3.4 55555 5.6.7.8 22");
    try std.testing.expectEqualStrings(
        remote_protocol_modes_string,
        protocolModesString(&env),
    );
    try std.testing.expect(
        ProtocolMode.kitty_shm.resolve(&env).unsupportedKittyReason() != null,
    );
    try std.testing.expect(
        ProtocolMode.kitty_temp.resolve(&env).unsupportedKittyReason() != null,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        ProtocolMode.kitty_direct.resolve(&env).unsupportedKittyReason(),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        ProtocolMode.kitty_rgba.resolve(&env).unsupportedKittyReason(),
    );
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

test "PreviewSize combines pixels/cells and resolves pixel dims" {
    const def: PreviewSize = .default;
    try std.testing.expect(!def.hasExplicitPixels());
    try std.testing.expectEqual(@as(?CellDims, null), def.cellDims());
    try std.testing.expectEqual(
        PreviewSize.default_pixels,
        def.resolveMaxPixels(null),
    );
    try std.testing.expect(!def.needsCellPixelSize(null));
    try std.testing.expect(!def.needsCellPixelSize(.{ .protocol = .kitty }));
    try std.testing.expect(def.needsCellPixelSize(.{
        .protocol = .kitty,
        .transport = .tmux_unicode_placeholders,
    }));
    try std.testing.expect(def.needsCellPixelSize(.{
        .protocol = .halfblocks,
    }));

    const c_only = def.withCells(.{ .cols = 60, .rows = 30 });
    try std.testing.expect(!c_only.hasExplicitPixels());
    try std.testing.expectEqual(
        @as(?CellDims, .{ .cols = 60, .rows = 30 }),
        c_only.cellDims(),
    );
    try std.testing.expect(c_only.needsCellPixelSize(null));
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 600, .h = 600 },
        c_only.resolveMaxPixels(.{ .w = 10, .h = 20 }),
    );

    // Combining cells then pixels (and pixels then cells) yields identical
    // pixels_and_cells preserving both explicit bounds.
    const both_a = c_only.withPixels(.{ .w = 400, .h = 300 });
    const both_b = def.withPixels(.{ .w = 400, .h = 300 }).withCells(.{
        .cols = 60,
        .rows = 30,
    });
    try std.testing.expectEqual(both_a, both_b);
    try std.testing.expect(both_a.hasExplicitPixels());
    try std.testing.expectEqual(
        @as(?CellDims, .{ .cols = 60, .rows = 30 }),
        both_a.cellDims(),
    );
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 400, .h = 300 },
        both_a.resolveMaxPixels(.{ .w = 16, .h = 32 }),
    );
    try std.testing.expect(!both_a.needsCellPixelSize(.{
        .protocol = .sixel,
    }));
    try std.testing.expect(!both_a.needsCellPixelSize(.{
        .protocol = .iterm2,
    }));
    try std.testing.expect(!both_a.needsCellPixelSize(.{
        .protocol = .kitty,
        .transport = .tmux_passthrough,
    }));
    // Repeated flags overwrite their own axis while preserving the other.
    try std.testing.expectEqual(
        PreviewSize{
            .pixels_and_cells = .{
                .pixels = .{ .w = 320, .h = 240 },
                .cells = .{ .cols = 80, .rows = 24 },
            },
        },
        both_a.withPixels(.{ .w = 320, .h = 240 }).withCells(.{
            .cols = 80,
            .rows = 24,
        }),
    );
    // `.cells` falls back to `default_cell_px` (10x20) when `cell_px` is null.
    try std.testing.expectEqual(
        PositiveDimsU32{ .w = 600, .h = 600 },
        c_only.resolveMaxPixels(null),
    );
}

test "isRemoteSession detects SSH environment variables" {
    try std.testing.expect(!isRemoteSession(.{}));
    try std.testing.expect(!isRemoteSession(.{ .ssh_connection = "" }));
    try std.testing.expect(isRemoteSession(.{
        .ssh_connection = "1.2.3.4 55555 5.6.7.8 22",
    }));
    try std.testing.expect(isRemoteSession(.{ .ssh_tty = "/dev/pts/1" }));
    try std.testing.expect(isRemoteSession(.{
        .ssh_client = "1.2.3.4 55555 22",
    }));
}

test "detectProtocol routes WT_SESSION to sixel without overriding explicit" {
    try std.testing.expectEqual(
        Protocol.sixel,
        detectProtocol(.{ .wt_session = "wt-session-1" }),
    );
    // Explicit terminal identity takes precedence over an inherited WT_SESSION.
    try std.testing.expectEqual(
        Protocol.iterm2,
        detectProtocol(.{
            .term_program = "WezTerm",
            .wt_session = "wt-session-1",
        }),
    );
    try std.testing.expectEqual(
        Protocol.kitty,
        detectProtocol(.{
            .kitty_window_id = "1",
            .wt_session = "wt-session-1",
        }),
    );
}

test "ResolvedTarget.reconcileKittyCapability respects mode and transport" {
    const direct_kitty: ResolvedTarget = .{ .protocol = .kitty };
    try std.testing.expectEqual(
        Protocol.kitty,
        direct_kitty.reconcileKittyCapability(.auto, true).protocol,
    );
    try std.testing.expectEqual(
        Protocol.halfblocks,
        direct_kitty.reconcileKittyCapability(.auto, false).protocol,
    );
    // Explicit --protocol kitty and tmux transports are never downgraded.
    try std.testing.expectEqual(
        Protocol.kitty,
        direct_kitty.reconcileKittyCapability(.kitty, false).protocol,
    );
    const tmux_kitty: ResolvedTarget = .{
        .protocol = .kitty,
        .transport = .tmux_unicode_placeholders,
    };
    try std.testing.expectEqual(
        Protocol.kitty,
        tmux_kitty.reconcileKittyCapability(.auto, false).protocol,
    );
    // Non-Kitty protocols are preserved regardless of has_kitty.
    try std.testing.expectEqual(
        Protocol.sixel,
        (ResolvedTarget{ .protocol = .sixel })
            .reconcileKittyCapability(.auto, false)
            .protocol,
    );
    try std.testing.expectEqual(
        Protocol.iterm2,
        (ResolvedTarget{ .protocol = .iterm2 })
            .reconcileKittyCapability(.auto, true)
            .protocol,
    );
    try std.testing.expectEqual(
        Protocol.halfblocks,
        (ResolvedTarget{ .protocol = .halfblocks })
            .reconcileKittyCapability(.auto, true)
            .protocol,
    );
}
