const builtin = @import("builtin");
const geom = @import("geom");
const intents = @import("intents");
const std = @import("std");
const termgfx = @import("termgfx");
const thumbcache = @import("thumbcache");

const CellDims = termgfx.CellDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const ProtocolMode = termgfx.ProtocolMode;
const ThumbCacheMode = thumbcache.ThumbCacheMode;
const ThumbTier = thumbcache.ThumbTier;
const protocol_modes_string = termgfx.protocol_modes_string;
const thumb_cache_modes_string = thumbcache.thumb_cache_modes_string;
const thumb_tiers_string = thumbcache.thumb_tiers_string;
const ZoomPreset = intents.ZoomPreset;

/// Startup process flags that configure runtime initialization (not runtime actions).
pub const process_flags = [_]intents.CliOption{
    .{
        .id = .help,
        .target = .both,
        .short = "-h",
        .long = "--help",
        .description = "Show this help message and exit",
    },
    .{
        .id = .thumb_cache,
        .target = .main,
        .long = "--thumb-cache",
        .arg_name = "<MODE>",
        .description = "Set XDG thumbnail cache policy (" ++
            thumb_cache_modes_string ++ ")",
    },
    .{
        .id = .thumb_size,
        .target = .main,
        .long = "--thumb-size",
        .arg_name = "<TIER>",
        .description = "Override XDG thumbnail write tier (" ++
            thumb_tiers_string ++ ")",
    },
    .{
        .id = .no_thumb_cache,
        .target = .main,
        .long = "--no-thumb-cache",
        .description = "Disable Freedesktop XDG shared thumbnail cache",
    },
    .{
        .id = .ipc,
        .target = .main,
        .long = "--ipc",
        .aliases = &.{"--enable-ipc"},
        .description = "Enable UNIX Domain Socket IPC server (/tmp/peng-$PID.sock)",
    },
    .{
        .id = .socket,
        .target = .both,
        .short = "-S",
        .long = "--socket",
        .aliases = &.{"--ipc-socket"},
        .arg_name = "<PATH>",
        .description = "Use an explicit UNIX domain socket path",
    },
    .{
        .id = .server,
        .target = .main,
        .long = "--server",
        .aliases = &.{"--daemon"},
        .description = "Run as a resident background server",
    },
    .{
        .id = .spawn,
        .target = .ipc,
        .short = "-s",
        .long = "--spawn",
        .aliases = &.{"--autospawn"},
        .description = "Spawn a resident peng --server if not running",
    },
    .{
        .id = .headless,
        .target = .main,
        .long = "--headless",
        .description = "Run offscreen without creating a window (for CI/scripts)",
    },
    .{
        .id = .test_mode,
        .target = .both,
        .long = "--test-mode",
        .description = "Run in deterministic test configuration",
        .hidden = true,
    },
    .{
        .id = .profile_startup,
        .target = .main,
        .long = "--profile-startup",
        .description = "Log cold-start milestone timings in milliseconds",
    },
};

/// Centralized declarative registry of all supported command-line options.
/// Merges process lifecycle flags with capabilities declared in the unified action registry.
pub const options = blk: {
    const act_opts = intents.actions.action_cli_options;
    var list: [process_flags.len + act_opts.len]intents.CliOption = undefined;
    list[0] = process_flags[0]; // -h, --help
    var idx: usize = 1;
    for (act_opts) |opt| {
        list[idx] = opt;
        idx += 1;
    }
    for (process_flags[1..]) |opt| {
        list[idx] = opt;
        idx += 1;
    }
    break :blk list;
};

/// Centralized declarative registry of common IPC control commands.
/// Projected directly from the unified action registry.
pub const ipc_commands = intents.actions.ipc_commands;

/// Finds a registered CliOption matching the provided argument string for a specific target scope.
pub fn findOptionFor(arg: []const u8, scope: intents.CliTarget) ?intents.CliOption {
    for (options) |opt| {
        if (opt.target.appliesTo(scope) and opt.matches(arg)) return opt;
    }
    return null;
}

/// Pads a compile-time string slice with spaces on the right to the specified minimum width.
pub fn padRight(comptime str: []const u8, comptime width: usize) []const u8 {
    var out: []const u8 = str;
    while (out.len < width) {
        out = out ++ " ";
    }
    return out;
}

/// Formats an option's flag presentation (short flag, long flag, aliases, and argument name).
fn formatOptionFlags(comptime opt: intents.CliOption) []const u8 {
    var col: []const u8 = "  ";
    if (opt.short) |s| {
        col = col ++ s ++ ", " ++ opt.long;
    } else {
        col = col ++ opt.long;
    }

    for (opt.aliases) |alias| {
        col = col ++ ", " ++ alias;
    }

    if (opt.arg_name) |arg| {
        col = col ++ " " ++ arg;
    }
    return col;
}

/// Formats the options section for the specified target application.
fn formatOptionsFor(
    comptime target: intents.CliTarget,
    comptime col_width: usize,
) []const u8 {
    var text: []const u8 = "";
    for (options) |opt| {
        if (!opt.target.appliesTo(target) or opt.hidden) continue;
        const flags_str = formatOptionFlags(opt);
        if (flags_str.len < col_width) {
            const col = padRight(flags_str, col_width);
            text = text ++ col ++ opt.description ++ "\n";
        } else {
            text = text ++ flags_str ++ "\n" ++ padRight("", col_width) ++ opt.description ++ "\n";
        }
    }
    return text;
}

/// Formats the IPC command list with aligned descriptions.
fn formatIpcCommands(comptime col_width: usize) []const u8 {
    var text: []const u8 = "";
    for (ipc_commands) |cmd| {
        var col: []const u8 = "  " ++ cmd.name;
        if (cmd.args) |arg| {
            col = col ++ " " ++ arg;
        }
        if (col.len < col_width) {
            text = text ++ padRight(col, col_width) ++ cmd.description ++ "\n";
        } else {
            text = text ++ col ++ "\n" ++ padRight("", col_width) ++ cmd.description ++ "\n";
        }
    }
    return text;
}

/// Specification for generating a standardized, formatted application help message.
pub const HelpSpec = struct {
    title: []const u8,
    usage: []const u8,
    arguments: ?[]const u8 = null,
    target: intents.CliTarget,
    options_col_width: usize = 29,
    extra_sections: ?[]const u8 = null,
};

/// Generates standardized, formatted help text at compile-time from a HelpSpec.
pub fn generateHelp(comptime spec: HelpSpec) []const u8 {
    var text: []const u8 = spec.title ++ "\n\nUsage:\n  " ++ spec.usage ++ "\n\n";

    if (spec.arguments) |args| {
        text = text ++ "Arguments:\n" ++ args ++ "\n\n";
    }

    text = text ++ "Options:\n" ++ formatOptionsFor(spec.target, spec.options_col_width);

    if (spec.extra_sections) |extra| {
        text = text ++ "\n" ++ extra;
    }

    return text;
}

/// Formatted application help text dynamically generated for the primary
/// `peng` viewer at compile-time.
pub const main_help_text: []const u8 = generateHelp(.{
    .title = "Peng — High-Performance GPU-Accelerated Image Viewer",
    .usage = "peng [options] [path]",
    .arguments =
    \\  [path]                     Path to an image file or directory to open.
    \\                             Can also read piped image paths from standard input.
    ,
    .target = .main,
    .options_col_width = 29,
});

/// Formatted help text dynamically generated for the `peng-msg` IPC utility at compile-time.
pub const ipc_help_text: []const u8 = generateHelp(.{
    .title = "Peng IPC Message Client",
    .usage = "peng-msg [options] [socket_path] <command_words...>",
    .target = .ipc,
    .options_col_width = 30,
    .extra_sections = "Common Commands:\n" ++ formatIpcCommands(30),
});

fn printHelpString(io: std.Io, text: []const u8) void {
    var stdout_write_buf: [4 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(
        io,
        &stdout_write_buf,
    );
    if (stdout_writer.interface.writeAll(text)) {
        stdout_writer.interface.flush() catch {};
    } else |_| {
        std.debug.print("{s}", .{text});
    }
}

/// Prints the primary application help text to standard output.
pub fn printHelp(io: std.Io) void {
    printHelpString(io, main_help_text);
}

/// Prints the IPC client help text to standard output.
pub fn printIpcHelp(io: std.Io) void {
    printHelpString(io, ipc_help_text);
}

/// IPC socket server configuration mode.
pub const IpcMode = union(enum) {
    disabled,
    pid_socket,
    default_socket,
    custom_socket: []const u8,

    /// Returns `true` if the IPC socket server should be started.
    pub fn isEnabled(self: IpcMode) bool {
        return switch (self) {
            .disabled => false,
            .pid_socket, .default_socket, .custom_socket => true,
        };
    }

    /// Returns the explicit socket path if configured via `--socket`, or `null`
    /// when disabled or using an environment/PID-derived socket path.
    pub fn customPath(self: IpcMode) ?[]const u8 {
        return switch (self) {
            .disabled, .pid_socket, .default_socket => null,
            .custom_socket => |p| p,
        };
    }

    /// Frees any owned custom socket path string and resets to `.disabled`.
    pub fn deinit(self: *IpcMode, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .disabled, .pid_socket, .default_socket => {},
            .custom_socket => |p| {
                gpa.free(p);
                self.* = .disabled;
            },
        }
    }
};

/// Parsed command-line configuration options controlling launch behavior and rendering modes.
pub const ParsedArgs = struct {
    arg_path: ?[]const u8 = null,
    default_scale: ZoomPreset = .full,
    test_mode: bool = false,
    profile_startup: bool = false,
    headless: bool = false,
    server_mode: bool = false,
    ipc_mode: IpcMode = .disabled,
    enable_blur: bool = true,
    show_title: bool = false,
    windowless: bool = false,
    stack_raw_jpeg: bool = true,
    thumb_cache: ThumbCacheMode = .all,
    thumb_size: ?ThumbTier = null,
    help: bool = false,

    /// Frees allocated memory associated with parsed command-line arguments.
    pub fn deinit(self: *ParsedArgs, gpa: std.mem.Allocator) void {
        if (self.arg_path) |p| {
            gpa.free(p);
            self.arg_path = null;
        }
        self.ipc_mode.deinit(gpa);
    }
};

/// Parsed command-line arguments for the `peng-msg` IPC client utility.
pub const ParsedIpcArgs = union(enum) {
    help,
    send: Send,

    /// Payload for an IPC command transmission.
    pub const Send = struct {
        socket_path: ?[]u8 = null,
        command: []u8,
        spawn: bool = false,
        test_mode: bool = false,

        /// Frees allocated memory for the socket path and command string.
        pub fn deinit(self: *Send, gpa: std.mem.Allocator) void {
            if (self.socket_path) |p| {
                gpa.free(p);
                self.socket_path = null;
            }
            gpa.free(self.command);
        }
    };

    /// Frees allocated memory for the socket path and command string.
    pub fn deinit(self: *ParsedIpcArgs, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .help => {},
            .send => |*s| s.deinit(gpa),
        }
    }
};

/// Iterator wrapper over a slice of argument strings, primarily used for unit testing.
pub const SliceIterator = struct {
    slice: []const []const u8,
    index: usize = 0,

    pub fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index < self.slice.len) {
            const item = self.slice[self.index];
            self.index += 1;
            return item;
        }
        return null;
    }
};

fn parseZoomPreset(val: []const u8) ?ZoomPreset {
    return ZoomPreset.parse(val);
}

fn parsePreviewSize(val: []const u8) ?PositiveDimsU32 {
    const sep = std.mem.findScalar(u8, val, 'x') orelse
        std.mem.findScalar(u8, val, 'X') orelse
        return null;
    const w = std.fmt.parseInt(u32, val[0..sep], 10) catch return null;
    const h = std.fmt.parseInt(u32, val[sep + 1 ..], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

/// Parses flags and arguments from any iterator providing `next() ?[]const u8`.
pub fn parseArgsIterator(args_it: anytype, gpa: std.mem.Allocator) !ParsedArgs {
    var arg_path: ?[]const u8 = null;
    errdefer if (arg_path) |p| gpa.free(p);

    var default_scale: ZoomPreset = .full;
    var test_mode = false;
    var profile_startup = false;
    var headless = false;
    var server_mode = false;
    var ipc_mode: IpcMode = .disabled;
    errdefer ipc_mode.deinit(gpa);
    var enable_blur = true;
    var show_title = false;
    var windowless = false;
    var stack_raw_jpeg = true;
    var thumb_cache: ThumbCacheMode = .all;
    var thumb_size: ?ThumbTier = null;
    var help = false;

    var end_of_options = false;

    while (args_it.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options) {
            if (findOptionFor(arg, .main)) |opt| {
                switch (opt.id) {
                    .help => help = true,
                    .test_mode => test_mode = true,
                    .headless => headless = true,
                    .profile_startup => profile_startup = true,
                    .server => {
                        server_mode = true;
                        switch (ipc_mode) {
                            .disabled, .pid_socket => {
                                ipc_mode = .default_socket;
                            },
                            .default_socket, .custom_socket => {},
                        }
                    },
                    .ipc => switch (ipc_mode) {
                        .disabled => ipc_mode = .pid_socket,
                        .pid_socket, .default_socket, .custom_socket => {},
                    },
                    .socket => {
                        const val = args_it.next() orelse {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Missing value for --socket flag.",
                                    .{},
                                );
                            }
                            return error.MissingFlagValue;
                        };
                        if (val.len == 0 or val.len >= 104) {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Invalid socket path length: {s}",
                                    .{val},
                                );
                            }
                            return error.InvalidSocketPath;
                        }
                        ipc_mode.deinit(gpa);
                        ipc_mode = .{ .custom_socket = try gpa.dupe(u8, val) };
                    },
                    .spawn => unreachable,
                    .blur => enable_blur = true,
                    .no_blur => enable_blur = false,
                    .title => show_title = true,
                    .windowless => windowless = true,
                    .stack_raw_jpeg => stack_raw_jpeg = true,
                    .no_stack_raw_jpeg => stack_raw_jpeg = false,
                    .no_thumb_cache => thumb_cache = .off,
                    .thumb_cache => {
                        const val = args_it.next() orelse {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Missing value for --thumb-cache flag.",
                                    .{},
                                );
                            }
                            return error.MissingFlagValue;
                        };
                        if (ThumbCacheMode.parse(val)) |mode| {
                            thumb_cache = mode;
                        } else {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Unknown thumb-cache mode: {s}. " ++
                                        "Valid: {s}.",
                                    .{ val, thumb_cache_modes_string },
                                );
                            }
                            return error.InvalidThumbCacheMode;
                        }
                    },
                    .thumb_size => {
                        const val = args_it.next() orelse {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Missing value for --thumb-size flag.",
                                    .{},
                                );
                            }
                            return error.MissingFlagValue;
                        };
                        if (ThumbTier.parse(val)) |tier| {
                            thumb_size = tier;
                        } else {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Unknown thumb-size tier: {s}. " ++
                                        "Valid: {s}.",
                                    .{ val, thumb_tiers_string },
                                );
                            }
                            return error.InvalidThumbSize;
                        }
                    },
                    .scale => {
                        const val = args_it.next() orelse {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Missing value for --scale flag.",
                                    .{},
                                );
                            }
                            return error.MissingFlagValue;
                        };
                        if (parseZoomPreset(val)) |mode| {
                            default_scale = mode;
                        } else {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Unknown scale mode: {s}. Valid: {s}.",
                                    .{ val, intents.scale_modes_string },
                                );
                            }
                            return error.InvalidScaleMode;
                        }
                    },
                }
                continue;
            } else if (arg.len > 1 and arg[0] == '-') {
                if (!builtin.is_test) {
                    std.log.err(
                        "Unknown flag: {s}. Use --help for usage information.",
                        .{arg},
                    );
                }
                return error.UnknownFlag;
            }
        }
        // Treat non-flag arguments (or arguments after `--`) as path
        if (arg_path == null) {
            arg_path = try gpa.dupe(u8, arg);
        }
    }

    return ParsedArgs{
        .arg_path = arg_path,
        .default_scale = default_scale,
        .test_mode = test_mode,
        .profile_startup = profile_startup,
        .headless = headless,
        .server_mode = server_mode,
        .ipc_mode = ipc_mode,
        .enable_blur = enable_blur,
        .show_title = show_title,
        .windowless = windowless,
        .stack_raw_jpeg = stack_raw_jpeg,
        .thumb_cache = thumb_cache,
        .thumb_size = thumb_size,
        .help = help,
    };
}

/// Parses command-line flags and positional target paths from the process invocation.
pub fn parseCommandLineArgs(init: std.process.Init, gpa: std.mem.Allocator) !ParsedArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    return parseArgsIterator(&args_it, gpa);
}

/// Returns `true` if `arg` looks like a Unix socket path (contains a path
/// separator `/` or `\` or ends with `.sock`) rather than an IPC command verb.
pub fn looksLikeSocketPath(arg: []const u8) bool {
    return std.mem.findAny(u8, arg, "/\\") != null or
        std.mem.endsWith(u8, arg, ".sock");
}

/// Parses `peng-msg` CLI options, optional socket path, and IPC command words
/// from any iterator providing `next() ?[]const u8`.
pub fn parseIpcArgsIterator(
    args_it: anytype,
    gpa: std.mem.Allocator,
) !ParsedIpcArgs {
    var socket_path: ?[]u8 = null;
    errdefer if (socket_path) |p| gpa.free(p);

    var command_buf: std.ArrayList(u8) = .empty;
    defer command_buf.deinit(gpa);

    var spawn = false;
    var test_mode = false;
    var help = false;
    var end_of_options = false;
    var in_command = false;

    while (args_it.next()) |arg| {
        if (!in_command and !end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!in_command and !end_of_options) {
            if (findOptionFor(arg, .ipc)) |opt| {
                switch (opt.id) {
                    .help => help = true,
                    .spawn => spawn = true,
                    .test_mode => test_mode = true,
                    .socket => {
                        const val = args_it.next() orelse {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Missing value for --socket flag.",
                                    .{},
                                );
                            }
                            return error.MissingFlagValue;
                        };
                        if (val.len == 0 or val.len >= 104) {
                            if (!builtin.is_test) {
                                std.log.err(
                                    "Invalid socket path length: {s}",
                                    .{val},
                                );
                            }
                            return error.InvalidSocketPath;
                        }
                        if (socket_path) |old| gpa.free(old);
                        socket_path = try gpa.dupe(u8, val);
                    },
                    .scale,
                    .blur,
                    .no_blur,
                    .title,
                    .ipc,
                    .server,
                    .headless,
                    .profile_startup,
                    .windowless,
                    .stack_raw_jpeg,
                    .no_stack_raw_jpeg,
                    .thumb_cache,
                    .thumb_size,
                    .no_thumb_cache,
                    => unreachable,
                }
                continue;
            } else if (arg.len > 1 and arg[0] == '-') {
                if (!builtin.is_test) {
                    std.log.err(
                        "Unknown flag: {s}. Use --help for usage information.",
                        .{arg},
                    );
                }
                return error.UnknownFlag;
            }
        }

        if (!in_command and socket_path == null and looksLikeSocketPath(arg)) {
            if (arg.len == 0 or arg.len >= 104) {
                if (!builtin.is_test) {
                    std.log.err("Invalid socket path length: {s}", .{arg});
                }
                return error.InvalidSocketPath;
            }
            socket_path = try gpa.dupe(u8, arg);
            continue;
        }

        in_command = true;
        if (command_buf.items.len > 0) {
            try command_buf.append(gpa, ' ');
        }
        try command_buf.appendSlice(gpa, arg);
    }

    if (help) {
        if (socket_path) |p| gpa.free(p);
        return .help;
    }

    if (command_buf.items.len == 0) {
        return error.MissingCommand;
    }
    try command_buf.append(gpa, '\n');

    return .{
        .send = .{
            .socket_path = socket_path,
            .command = try command_buf.toOwnedSlice(gpa),
            .spawn = spawn,
            .test_mode = test_mode,
        },
    };
}

/// Parses `peng-msg` command-line flags, optional socket path, and IPC command
/// words.
pub fn parseIpcCommandLineArgs(
    init: std.process.Init,
    gpa: std.mem.Allocator,
) !ParsedIpcArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    return parseIpcArgsIterator(&args_it, gpa);
}

/// Parsed command-line arguments for the `peng-preview` standalone utility.
pub const PreviewArgs = struct {
    path: ?[]u8 = null,
    output_path: ?[]u8 = null,
    max_dims: PositiveDimsU32 = .{ .w = 800, .h = 600 },
    cell_dims: ?CellDims = null,
    clear_first: bool = false,
    protocol: ProtocolMode = .auto,
    thumb_cache: ThumbCacheMode = .all,
    help: bool = false,

    /// Releases owned path memory.
    pub fn deinit(self: *PreviewArgs, gpa: std.mem.Allocator) void {
        if (self.path) |p| {
            gpa.free(p);
            self.path = null;
        }
        if (self.output_path) |p| {
            gpa.free(p);
            self.output_path = null;
        }
    }
};

/// Prints `peng-preview` usage information to standard output.
pub fn printPreviewHelp(io: std.Io) void {
    printHelpString(
        io,
        "Usage: peng-preview [OPTIONS] [W H] <PATH>\n\n" ++
            "Render a terminal image preview (Kitty, Sixel, or iTerm2) " ++
            "or write a JPEG/PNG preview file with -o/--output.\n\n" ++
            "Options:\n" ++
            "  -h, --help                Show this help message and exit\n" ++
            "  -c, --clear               " ++
            "Clear prior terminal graphics first (Kitty)\n" ++
            "  -o, --output <PATH>       " ++
            "Write encoded JPEG/PNG preview to file instead of stdout\n" ++
            "      --protocol <MODE>     Terminal graphics protocol (" ++
            protocol_modes_string ++ "; default: auto)\n" ++
            "      --size <WxH>          " ++
            "Maximum pixel dimensions (default: 800x600)\n" ++
            "      --cells <COLSxROWS>   " ++
            "Target terminal cell grid (for Kitty U=1 / tmux)\n" ++
            "      --thumb-cache <MODE>  XDG thumbnail cache policy (" ++
            thumb_cache_modes_string ++ ")\n" ++
            "      --no-thumb-cache      Disable XDG shared thumbnail cache\n",
    );
}

fn parsePreviewArgsIterator(
    args_it: anytype,
    gpa: std.mem.Allocator,
) !PreviewArgs {
    var clear_first = false;
    var output_path: ?[]u8 = null;
    errdefer if (output_path) |p| gpa.free(p);
    var max_dims: PositiveDimsU32 = .{ .w = 800, .h = 600 };
    var cell_dims: ?CellDims = null;
    var has_flag_size = false;
    var protocol: ProtocolMode = .auto;
    var thumb_cache: ThumbCacheMode = .all;
    var help = false;
    var end_of_options = false;

    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    while (args_it.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                help = true;
            } else if (std.mem.eql(u8, arg, "-c") or
                std.mem.eql(u8, arg, "--clear"))
            {
                clear_first = true;
            } else if (std.mem.eql(u8, arg, "-o") or
                std.mem.eql(u8, arg, "--output"))
            {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err("Missing value for --output flag.", .{});
                    }
                    return error.MissingFlagValue;
                };
                if (val.len == 0) {
                    if (!builtin.is_test) {
                        std.log.err("Empty value for --output flag.", .{});
                    }
                    return error.InvalidOutputPath;
                }
                const duped = try gpa.dupe(u8, val);
                if (output_path) |old| gpa.free(old);
                output_path = duped;
            } else if (std.mem.eql(u8, arg, "--no-thumb-cache")) {
                thumb_cache = .off;
            } else if (std.mem.eql(u8, arg, "--protocol")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err("Missing value for --protocol flag.", .{});
                    }
                    return error.MissingFlagValue;
                };
                protocol = ProtocolMode.parse(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Unknown protocol: {s}. Valid: {s}.",
                            .{ val, protocol_modes_string },
                        );
                    }
                    return error.InvalidProtocol;
                };
            } else if (std.mem.eql(u8, arg, "--cells")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err("Missing value for --cells flag.", .{});
                    }
                    return error.MissingFlagValue;
                };
                const dims = parsePreviewSize(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Invalid --cells value: {s}. Expected COLSxROWS.",
                            .{val},
                        );
                    }
                    return error.InvalidPreviewSize;
                };
                cell_dims = .{ .cols = dims.w, .rows = dims.h };
            } else if (std.mem.eql(u8, arg, "--size")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err("Missing value for --size flag.", .{});
                    }
                    return error.MissingFlagValue;
                };
                max_dims = parsePreviewSize(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Invalid --size value: {s}. Expected WxH.",
                            .{val},
                        );
                    }
                    return error.InvalidPreviewSize;
                };
                has_flag_size = true;
            } else if (std.mem.eql(u8, arg, "--thumb-cache")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Missing value for --thumb-cache flag.",
                            .{},
                        );
                    }
                    return error.MissingFlagValue;
                };
                thumb_cache = ThumbCacheMode.parse(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Unknown thumb-cache mode: {s}. Valid: {s}.",
                            .{ val, thumb_cache_modes_string },
                        );
                    }
                    return error.InvalidThumbCacheMode;
                };
            } else {
                if (!builtin.is_test) {
                    std.log.err(
                        "Unknown flag: {s}. Use --help for usage.",
                        .{arg},
                    );
                }
                return error.UnknownFlag;
            }
            continue;
        }
        try positional.append(gpa, arg);
    }

    if (help) {
        if (output_path) |p| gpa.free(p);
        return .{ .help = true };
    }

    var path_slice: ?[]const u8 = null;
    if (positional.items.len == 1) {
        path_slice = positional.items[0];
    } else if (positional.items.len == 3 and !has_flag_size) {
        const w = std.fmt.parseInt(u32, positional.items[0], 10) catch {
            if (!builtin.is_test) {
                std.log.err("Invalid width: {s}", .{positional.items[0]});
            }
            return error.InvalidPreviewSize;
        };
        const h = std.fmt.parseInt(u32, positional.items[1], 10) catch {
            if (!builtin.is_test) {
                std.log.err("Invalid height: {s}", .{positional.items[1]});
            }
            return error.InvalidPreviewSize;
        };
        if (w == 0 or h == 0) {
            if (!builtin.is_test) {
                std.log.err("Preview dimensions must be positive.", .{});
            }
            return error.InvalidPreviewSize;
        }
        max_dims = .{ .w = w, .h = h };
        path_slice = positional.items[2];
    } else if (positional.items.len > 1) {
        if (!builtin.is_test) {
            std.log.err("Too many positional arguments. Use --help.", .{});
        }
        return error.TooManyArguments;
    }

    const owned_path: ?[]u8 = if (path_slice) |p|
        try gpa.dupe(u8, p)
    else
        null;

    return .{
        .path = owned_path,
        .output_path = output_path,
        .max_dims = max_dims,
        .cell_dims = cell_dims,
        .clear_first = clear_first,
        .protocol = protocol,
        .thumb_cache = thumb_cache,
        .help = false,
    };
}

/// Parses `peng-preview` command-line flags and target path.
pub fn parsePreviewArgs(
    init: std.process.Init,
    gpa: std.mem.Allocator,
) !PreviewArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer args_it.deinit();
    _ = args_it.next();
    return parsePreviewArgsIterator(&args_it, gpa);
}

/// Parsed command-line arguments for the `peng-precache` standalone utility.
pub const PrecacheArgs = struct {
    path: ?[]u8 = null,
    recursive: bool = false,
    thumb_cache: ThumbCacheMode = .all,
    thumb_size: ?ThumbTier = null,
    help: bool = false,

    /// Releases owned path memory.
    pub fn deinit(self: *PrecacheArgs, gpa: std.mem.Allocator) void {
        if (self.path) |p| {
            gpa.free(p);
            self.path = null;
        }
    }
};

/// Prints `peng-precache` usage information to standard output.
pub fn printPrecacheHelp(io: std.Io) void {
    printHelpString(
        io,
        "Usage: peng-precache [OPTIONS] [PATH]\n\n" ++
            "Pre-generate Freedesktop shared thumbnails in parallel " ++
            "(default PATH: '.').\n\n" ++
            "Options:\n" ++
            "  -h, --help                Show this help message and exit\n" ++
            "  -r, --recursive           Recursively scan subdirectories\n" ++
            "      --thumb-cache <MODE>  " ++
            "XDG thumbnail write policy (all, missing)\n" ++
            "      --thumb-size <TIER>   Override XDG thumbnail write tier (" ++
            thumb_tiers_string ++ ")\n",
    );
}

fn parsePrecacheArgsIterator(
    args_it: anytype,
    gpa: std.mem.Allocator,
) !PrecacheArgs {
    var path: ?[]u8 = null;
    errdefer if (path) |p| gpa.free(p);
    var recursive = false;
    var thumb_cache: ThumbCacheMode = .all;
    var thumb_size: ?ThumbTier = null;
    var help = false;
    var end_of_options = false;

    while (args_it.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                help = true;
            } else if (std.mem.eql(u8, arg, "-r") or
                std.mem.eql(u8, arg, "-R") or
                std.mem.eql(u8, arg, "--recursive"))
            {
                recursive = true;
            } else if (std.mem.eql(u8, arg, "--thumb-cache")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Missing value for --thumb-cache flag.",
                            .{},
                        );
                    }
                    return error.MissingFlagValue;
                };
                const mode = ThumbCacheMode.parse(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Unknown thumb-cache mode: {s}. " ++
                                "Valid: all, missing.",
                            .{val},
                        );
                    }
                    return error.InvalidThumbCacheMode;
                };
                switch (mode) {
                    .all, .missing => thumb_cache = mode,
                    .read_only, .off => {
                        if (!builtin.is_test) {
                            std.log.err(
                                "Invalid --thumb-cache mode for " ++
                                    "peng-precache: {s}. Valid: all, missing.",
                                .{val},
                            );
                        }
                        return error.InvalidThumbCacheMode;
                    },
                }
            } else if (std.mem.eql(u8, arg, "--thumb-size")) {
                const val = args_it.next() orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Missing value for --thumb-size flag.",
                            .{},
                        );
                    }
                    return error.MissingFlagValue;
                };
                thumb_size = ThumbTier.parse(val) orelse {
                    if (!builtin.is_test) {
                        std.log.err(
                            "Unknown thumb-size tier: {s}. Valid: {s}.",
                            .{ val, thumb_tiers_string },
                        );
                    }
                    return error.InvalidThumbSize;
                };
            } else {
                if (!builtin.is_test) {
                    std.log.err(
                        "Unknown flag: {s}. Use --help for usage.",
                        .{arg},
                    );
                }
                return error.UnknownFlag;
            }
            continue;
        }
        if (path != null) {
            if (!builtin.is_test) {
                std.log.err("Too many positional arguments. Use --help.", .{});
            }
            return error.TooManyArguments;
        }
        path = try gpa.dupe(u8, arg);
    }

    return .{
        .path = path,
        .recursive = recursive,
        .thumb_cache = thumb_cache,
        .thumb_size = thumb_size,
        .help = help,
    };
}

/// Parses `peng-precache` command-line flags and optional target path.
pub fn parsePrecacheArgs(
    init: std.process.Init,
    gpa: std.mem.Allocator,
) !PrecacheArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer args_it.deinit();
    _ = args_it.next();
    return parsePrecacheArgsIterator(&args_it, gpa);
}

test "CliTarget appliesTo works correctly" {
    const testing = std.testing;
    try testing.expect(intents.CliTarget.both.appliesTo(.main));
    try testing.expect(intents.CliTarget.both.appliesTo(.ipc));
    try testing.expect(intents.CliTarget.both.appliesTo(.both));

    try testing.expect(intents.CliTarget.main.appliesTo(.main));
    try testing.expect(!intents.CliTarget.main.appliesTo(.ipc));
    try testing.expect(intents.CliTarget.main.appliesTo(.both));

    try testing.expect(!intents.CliTarget.ipc.appliesTo(.main));
    try testing.expect(intents.CliTarget.ipc.appliesTo(.ipc));
    try testing.expect(intents.CliTarget.ipc.appliesTo(.both));
}

test "scale_modes_string and filter_modes_string contain enum variants" {
    const testing = std.testing;
    const scale_str = intents.scale_modes_string;
    const filter_str = intents.filter_modes_string;
    try testing.expect(std.mem.find(u8, scale_str, "full") != null);
    try testing.expect(std.mem.find(u8, scale_str, "fit_width") != null);
    try testing.expect(std.mem.find(u8, filter_str, "mitchell") != null);
    try testing.expect(std.mem.find(u8, filter_str, "lanczos3") != null);
    try testing.expect(std.mem.find(u8, filter_str, "fsr") != null);
    try testing.expect(std.mem.find(u8, filter_str, "tiny_cnn") != null);
}

test "help_text and ipc_help_text contain visible options only" {
    const testing = std.testing;
    for (options) |opt| {
        if (opt.target.appliesTo(.main)) {
            const has_long = std.mem.find(u8, main_help_text, opt.long) != null;
            try testing.expectEqual(!opt.hidden, has_long);
            if (opt.short) |s| {
                const has_short = std.mem.find(u8, main_help_text, s) != null;
                try testing.expectEqual(!opt.hidden, has_short);
            }
        }
        if (opt.target.appliesTo(.ipc)) {
            const has_long = std.mem.find(u8, ipc_help_text, opt.long) != null;
            try testing.expectEqual(!opt.hidden, has_long);
            if (opt.short) |s| {
                const has_short = std.mem.find(u8, ipc_help_text, s) != null;
                try testing.expectEqual(!opt.hidden, has_short);
            }
        }
    }

    for (ipc_commands) |cmd| {
        try testing.expect(std.mem.find(u8, ipc_help_text, cmd.name) != null);
    }
}

test "findOptionFor respects target filtering" {
    const testing = std.testing;

    try testing.expectEqual(intents.OptionId.help, findOptionFor("-h", .main).?.id);
    try testing.expectEqual(intents.OptionId.help, findOptionFor("-h", .ipc).?.id);

    try testing.expectEqual(intents.OptionId.scale, findOptionFor("--scale", .main).?.id);
    try testing.expect(findOptionFor("--scale", .ipc) == null);

    try testing.expectEqual(intents.OptionId.ipc, findOptionFor("--ipc", .main).?.id);
    try testing.expect(findOptionFor("--ipc", .ipc) == null);

    try testing.expect(findOptionFor("--unknown", .main) == null);
    try testing.expect(findOptionFor("photo.jpg", .main) == null);
}

test "parseArgsIterator handles help flags" {
    const testing = std.testing;

    {
        var it = SliceIterator{ .slice = &[_][]const u8{"--help"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.help);
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{"-h"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.help);
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{ "--scale", "crop", "-h" } };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.help);
        try testing.expectEqual(ZoomPreset.crop, parsed.default_scale);
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{"some_photo.jpg"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.help);
        try testing.expectEqualStrings("some_photo.jpg", parsed.arg_path.?);
    }
}

test "parseArgsIterator handles blur and other flags" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "--no-blur",
                "--ipc",
                "--headless",
                "--test-mode",
                "--title",
            },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.enable_blur);
        try testing.expect(parsed.ipc_mode.isEnabled());
        try testing.expectEqual(
            @as(?[]const u8, null),
            parsed.ipc_mode.customPath(),
        );
        try testing.expect(parsed.headless);
        try testing.expect(parsed.test_mode);
        try testing.expect(parsed.show_title);
        try testing.expect(!parsed.help);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "--disable-blur",
                "--enable-ipc",
                "--title-overlay",
            },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.enable_blur);
        try testing.expect(parsed.ipc_mode.isEnabled());
        try testing.expect(parsed.show_title);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--socket", "/tmp/peng.sock", "--ipc" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.ipc_mode.isEnabled());
        try testing.expectEqualStrings(
            "/tmp/peng.sock",
            parsed.ipc_mode.customPath().?,
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "-S", "/tmp/custom.sock" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings(
            "/tmp/custom.sock",
            parsed.ipc_mode.customPath().?,
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--socket"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--socket", "" },
        };
        try testing.expectError(
            error.InvalidSocketPath,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{ "--enable-blur", "--blur" } };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.enable_blur);
        try testing.expect(!parsed.show_title);
    }
}

test "parseArgsIterator handles windowless flags" {
    const testing = std.testing;

    // Test -W short flag
    {
        var it = SliceIterator{ .slice = &[_][]const u8{"-W"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.windowless);
    }

    // Test --windowless long flag
    {
        var it = SliceIterator{ .slice = &[_][]const u8{"--windowless"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.windowless);
    }

    // Test --borderless alias
    {
        var it = SliceIterator{ .slice = &[_][]const u8{"--borderless"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.windowless);
    }

    // Test --undecorated alias
    {
        var it = SliceIterator{ .slice = &[_][]const u8{"--undecorated"} };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.windowless);
    }
}

test "parseArgsIterator rejects unknown flags and honors -- separator" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "photo.jpg", "--unknown-flag" },
        };
        try testing.expectError(
            error.UnknownFlag,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--update-baselines"},
        };
        try testing.expectError(
            error.UnknownFlag,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--scale"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--scale", "bogus" },
        };
        try testing.expectError(
            error.InvalidScaleMode,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--", "-dash-file.jpg" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings("-dash-file.jpg", parsed.arg_path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--scale", "width" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ZoomPreset.fit_width, parsed.default_scale);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--scale", "height" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ZoomPreset.fit_height, parsed.default_scale);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-cache", "missing" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ThumbCacheMode.missing, parsed.thumb_cache);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-cache", "read-only" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ThumbCacheMode.read_only, parsed.thumb_cache);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--no-thumb-cache"},
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ThumbCacheMode.off, parsed.thumb_cache);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--thumb-cache"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-cache", "invalid" },
        };
        try testing.expectError(
            error.InvalidThumbCacheMode,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-size", "normal" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ThumbTier.normal, parsed.thumb_size.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-size", "x-large" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ThumbTier.x_large, parsed.thumb_size.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--thumb-size"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-size", "invalid" },
        };
        try testing.expectError(
            error.InvalidThumbSize,
            parseArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--server"},
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.server_mode);
        try testing.expect(parsed.ipc_mode == .default_socket);
        try testing.expect(parsed.ipc_mode.isEnabled());
        try testing.expectEqual(
            @as(?[]const u8, null),
            parsed.ipc_mode.customPath(),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--server", "-S", "/tmp/srv.sock" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.server_mode);
        try testing.expectEqualStrings(
            "/tmp/srv.sock",
            parsed.ipc_mode.customPath().?,
        );
    }
}

test "parsePreviewArgsIterator supports positional W H and --size WxH" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "-c", "640", "480", "photo.jpg" },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.clear_first);
        try testing.expectEqual(@as(u32, 640), parsed.max_dims.w);
        try testing.expectEqual(@as(u32, 480), parsed.max_dims.h);
        try testing.expectEqualStrings("photo.jpg", parsed.path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "--clear",
                "--size",
                "1024x768",
                "--no-thumb-cache",
                "photo.RAF",
            },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.clear_first);
        try testing.expectEqual(@as(u32, 1024), parsed.max_dims.w);
        try testing.expectEqual(@as(u32, 768), parsed.max_dims.h);
        try testing.expectEqual(ThumbCacheMode.off, parsed.thumb_cache);
        try testing.expectEqualStrings("photo.RAF", parsed.path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--size", "0x600", "a.jpg" },
        };
        try testing.expectError(
            error.InvalidPreviewSize,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "--size",
                "800x600",
                "640",
                "480",
                "a.jpg",
            },
        };
        try testing.expectError(
            error.TooManyArguments,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "640", "a.jpg" },
        };
        try testing.expectError(
            error.TooManyArguments,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--", "-dash.jpg" },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings("-dash.jpg", parsed.path.?);
    }
}

test "parsePrecacheArgsIterator parses flags and optional path" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "-r",
                "--thumb-cache",
                "missing",
                "--thumb-size",
                "x-large",
                "photos",
            },
        };
        var parsed = try parsePrecacheArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.recursive);
        try testing.expectEqual(ThumbCacheMode.missing, parsed.thumb_cache);
        try testing.expectEqual(ThumbTier.x_large, parsed.thumb_size.?);
        try testing.expectEqualStrings("photos", parsed.path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--recursive"},
        };
        var parsed = try parsePrecacheArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.recursive);
        try testing.expect(parsed.path == null);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-cache", "read_only" },
        };
        try testing.expectError(
            error.InvalidThumbCacheMode,
            parsePrecacheArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--thumb-cache", "off" },
        };
        try testing.expectError(
            error.InvalidThumbCacheMode,
            parsePrecacheArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "dir1", "dir2" },
        };
        try testing.expectError(
            error.TooManyArguments,
            parsePrecacheArgsIterator(&it, testing.allocator),
        );
    }
}

test "parseIpcArgsIterator handles explicit/default socket and --spawn" {
    const testing = std.testing;

    // 1. Positional socket path + command words
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "/tmp/peng.sock", "open", "photo.jpg" },
        };
        var parsed = try parseIpcArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.send.spawn);
        try testing.expectEqualStrings(
            "/tmp/peng.sock",
            parsed.send.socket_path.?,
        );
        try testing.expectEqualStrings("open photo.jpg\n", parsed.send.command);
    }

    // 2. Default socket (no socket path given) + --spawn
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "-s", "open", "/home/user/photo.jpg" },
        };
        var parsed = try parseIpcArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.send.spawn);
        try testing.expectEqual(@as(?[]u8, null), parsed.send.socket_path);
        try testing.expectEqualStrings(
            "open /home/user/photo.jpg\n",
            parsed.send.command,
        );
    }

    // 3. Explicit -S / --socket flag + --spawn
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--spawn", "-S", "custom_name", "quit" },
        };
        var parsed = try parseIpcArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.send.spawn);
        try testing.expectEqualStrings(
            "custom_name",
            parsed.send.socket_path.?,
        );
        try testing.expectEqualStrings("quit\n", parsed.send.command);
    }

    // 3b. Hidden --test-mode flag alongside --spawn
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--spawn", "--test-mode", "open" },
        };
        var parsed = try parseIpcArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.send.spawn);
        try testing.expect(parsed.send.test_mode);
        try testing.expectEqualStrings("open\n", parsed.send.command);
    }

    // 4. Negative numeric arguments after command verb are preserved
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "/tmp/peng.sock",
                "adjust",
                "-0.25",
                "1.2",
            },
        };
        var parsed = try parseIpcArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings(
            "adjust -0.25 1.2\n",
            parsed.send.command,
        );
    }

    // 5. Missing command returns error.MissingCommand
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"/tmp/peng.sock"},
        };
        try testing.expectError(
            error.MissingCommand,
            parseIpcArgsIterator(&it, testing.allocator),
        );
    }
}

test "parsePreviewArgsIterator parses --protocol flag" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--protocol", "sixel", "photo.jpg" },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ProtocolMode.sixel, parsed.protocol);
        try testing.expectEqualStrings("photo.jpg", parsed.path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "--protocol",
                "iterm2",
                "--cells",
                "60x30",
                "photo.jpg",
            },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(ProtocolMode.iterm2, parsed.protocol);
        try testing.expectEqual(
            @as(?CellDims, .{ .cols = 60, .rows = 30 }),
            parsed.cell_dims,
        );
        try testing.expectEqualStrings("photo.jpg", parsed.path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--cells", "0x24", "photo.jpg" },
        };
        try testing.expectError(
            error.InvalidPreviewSize,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--cells"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--protocol", "invalid", "photo.jpg" },
        };
        try testing.expectError(
            error.InvalidProtocol,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }
}

test "parsePreviewArgsIterator parses --output flag and frees on errors" {
    const testing = std.testing;

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "-o", "/tmp/out.jpg", "photo.dng" },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings("/tmp/out.jpg", parsed.output_path.?);
        try testing.expectEqualStrings("photo.dng", parsed.path.?);
    }

    // Repeated flags replace prior allocation without leaking.
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "-o",
                "/tmp/a.jpg",
                "--output",
                "/tmp/b.jpg",
                "photo.jpg",
            },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqualStrings("/tmp/b.jpg", parsed.output_path.?);
    }

    // Early --help frees already-parsed output_path without leaking.
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "-o", "/tmp/a.jpg", "--help" },
        };
        var parsed = try parsePreviewArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.help);
        try testing.expectEqual(@as(?[]u8, null), parsed.output_path);
    }

    // Subsequent parse error frees output_path via errdefer.
    {
        var it = SliceIterator{
            .slice = &[_][]const u8{
                "-o",
                "/tmp/a.jpg",
                "--protocol",
                "invalid",
                "photo.jpg",
            },
        };
        try testing.expectError(
            error.InvalidProtocol,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{"--output"},
        };
        try testing.expectError(
            error.MissingFlagValue,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--output", "", "photo.jpg" },
        };
        try testing.expectError(
            error.InvalidOutputPath,
            parsePreviewArgsIterator(&it, testing.allocator),
        );
    }
}
