const builtin = @import("builtin");
const intents = @import("intents");
const std = @import("std");

const ThumbCacheMode = intents.ThumbCacheMode;
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
            intents.thumb_cache_modes_string ++ ")",
    },
    .{
        .id = .no_thumb_cache,
        .target = .main,
        .long = "--no-thumb-cache",
        .description = "Disable Freedesktop XDG shared thumbnail cache",
    },
    .{
        .id = .precache,
        .target = .main,
        .long = "--precache",
        .aliases = &.{"--cache-thumbs"},
        .description = "Pre-generate Freedesktop thumbnails for path and exit",
    },
    .{
        .id = .recursive,
        .target = .main,
        .short = "-r",
        .long = "--recursive",
        .aliases = &.{"-R"},
        .description = "Recursively scan subdirectories when pre-caching",
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
        .target = .main,
        .short = "-S",
        .long = "--socket",
        .aliases = &.{"--ipc-socket"},
        .arg_name = "<PATH>",
        .description = "Enable IPC server bound to an explicit socket path",
    },
    .{
        .id = .headless,
        .target = .main,
        .long = "--headless",
        .description = "Run offscreen without creating a window (for CI/scripts)",
    },
    .{
        .id = .test_mode,
        .target = .main,
        .long = "--test-mode",
        .description = "Run in test configuration (disables high-DPI scaling)",
    },
    .{
        .id = .update_baselines,
        .target = .main,
        .long = "--update-baselines",
        .description = "Update golden baseline screenshots during tests",
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
fn formatOptionsFor(comptime target: intents.CliTarget, comptime col_width: usize) []const u8 {
    var text: []const u8 = "";
    for (options) |opt| {
        if (!opt.target.appliesTo(target)) continue;
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
    .usage = "peng-msg <socket_path> <command_words...>",
    .target = .ipc,
    .options_col_width = 16,
    .extra_sections = "Common Commands:\n" ++ formatIpcCommands(30),
});

fn printHelpString(io: std.Io, text: []const u8) void {
    var stdout_write_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_write_buf);
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
    custom_socket: []const u8,

    /// Returns `true` if the IPC socket server should be started.
    pub fn isEnabled(self: IpcMode) bool {
        return switch (self) {
            .disabled => false,
            .pid_socket, .custom_socket => true,
        };
    }

    /// Returns the explicit socket path if configured via `--socket`, or `null`
    /// when disabled or using the default PID-based socket path.
    pub fn customPath(self: IpcMode) ?[]const u8 {
        return switch (self) {
            .disabled, .pid_socket => null,
            .custom_socket => |p| p,
        };
    }

    /// Frees any owned custom socket path string and resets to `.disabled`.
    pub fn deinit(self: *IpcMode, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .disabled, .pid_socket => {},
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
    update_baselines: bool = false,
    headless: bool = false,
    ipc_mode: IpcMode = .disabled,
    enable_blur: bool = true,
    show_title: bool = false,
    windowless: bool = false,
    stack_raw_jpeg: bool = true,
    thumb_cache: ThumbCacheMode = .all,
    precache: bool = false,
    recursive: bool = false,
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

/// Parses flags and arguments from any iterator providing `next() ?[]const u8`.
pub fn parseArgsIterator(args_it: anytype, gpa: std.mem.Allocator) !ParsedArgs {
    var arg_path: ?[]const u8 = null;
    errdefer if (arg_path) |p| gpa.free(p);

    var default_scale: ZoomPreset = .full;
    var test_mode = false;
    var update_baselines = false;
    var headless = false;
    var ipc_mode: IpcMode = .disabled;
    errdefer ipc_mode.deinit(gpa);
    var enable_blur = true;
    var show_title = false;
    var windowless = false;
    var stack_raw_jpeg = true;
    var thumb_cache: ThumbCacheMode = .all;
    var precache = false;
    var recursive = false;
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
                    .update_baselines => update_baselines = true,
                    .ipc => switch (ipc_mode) {
                        .disabled => ipc_mode = .pid_socket,
                        .pid_socket, .custom_socket => {},
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
                    .blur => enable_blur = true,
                    .no_blur => enable_blur = false,
                    .title => show_title = true,
                    .windowless => windowless = true,
                    .stack_raw_jpeg => stack_raw_jpeg = true,
                    .no_stack_raw_jpeg => stack_raw_jpeg = false,
                    .no_thumb_cache => thumb_cache = .off,
                    .precache => precache = true,
                    .recursive => recursive = true,
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
                                    .{ val, intents.thumb_cache_modes_string },
                                );
                            }
                            return error.InvalidThumbCacheMode;
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
        .update_baselines = update_baselines,
        .headless = headless,
        .ipc_mode = ipc_mode,
        .enable_blur = enable_blur,
        .show_title = show_title,
        .windowless = windowless,
        .stack_raw_jpeg = stack_raw_jpeg,
        .thumb_cache = thumb_cache,
        .precache = precache,
        .recursive = recursive,
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

test "help_text and ipc_help_text contain registered options" {
    const testing = std.testing;
    for (options) |opt| {
        if (opt.target.appliesTo(.main)) {
            const has_long = std.mem.find(u8, main_help_text, opt.long) != null;
            try testing.expect(has_long);
            if (opt.short) |s| {
                const has_short = std.mem.find(u8, main_help_text, s) != null;
                try testing.expect(has_short);
            }
        }
        if (opt.target.appliesTo(.ipc)) {
            const has_long = std.mem.find(u8, ipc_help_text, opt.long) != null;
            try testing.expect(has_long);
            if (opt.short) |s| {
                const has_short = std.mem.find(u8, ipc_help_text, s) != null;
                try testing.expect(has_short);
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
            .slice = &[_][]const u8{ "--precache", "-r", "photos" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.precache);
        try testing.expect(parsed.recursive);
        try testing.expectEqualStrings("photos", parsed.arg_path.?);
    }

    {
        var it = SliceIterator{
            .slice = &[_][]const u8{ "--cache-thumbs", "--recursive" },
        };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.precache);
        try testing.expect(parsed.recursive);
    }
}
