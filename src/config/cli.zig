const intents = @import("intents");
const std = @import("std");

const ScaleMode = intents.ScaleMode;

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
        .id = .ipc,
        .target = .main,
        .long = "--ipc",
        .aliases = &.{"--enable-ipc"},
        .description = "Enable UNIX Domain Socket IPC server (/tmp/peng-$PID.sock)",
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

/// Backward-compatible alias for the main application help text.
pub const help_text = main_help_text;

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

/// Parsed command-line configuration options controlling launch behavior and rendering modes.
pub const ParsedArgs = struct {
    arg_path: ?[]const u8 = null,
    default_scale: ScaleMode = .full,
    test_mode: bool = false,
    update_baselines: bool = false,
    headless: bool = false,
    ipc_enabled: bool = false,
    enable_blur: bool = true,
    show_title: bool = false,
    windowless: bool = false,
    stack_raw_jpeg: bool = true,
    help: bool = false,

    /// Frees allocated memory associated with parsed command-line arguments.
    pub fn deinit(self: *ParsedArgs, gpa: std.mem.Allocator) void {
        if (self.arg_path) |p| {
            gpa.free(p);
            self.arg_path = null;
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

/// Parses flags and arguments from any iterator providing `next() ?[]const u8`.
pub fn parseArgsIterator(args_it: anytype, gpa: std.mem.Allocator) !ParsedArgs {
    var arg_path: ?[]const u8 = null;
    errdefer if (arg_path) |p| gpa.free(p);

    var default_scale: ScaleMode = .full;
    var test_mode = false;
    var update_baselines = false;
    var headless = false;
    var ipc_enabled = false;
    var enable_blur = true;
    var show_title = false;
    var windowless = false;
    var stack_raw_jpeg = true;
    var help = false;

    while (args_it.next()) |arg| {
        if (findOptionFor(arg, .main)) |opt| {
            switch (opt.id) {
                .help => help = true,
                .test_mode => test_mode = true,
                .headless => headless = true,
                .update_baselines => update_baselines = true,
                .ipc => ipc_enabled = true,
                .blur => enable_blur = true,
                .no_blur => enable_blur = false,
                .title => show_title = true,
                .windowless => windowless = true,
                .stack_raw_jpeg => stack_raw_jpeg = true,
                .no_stack_raw_jpeg => stack_raw_jpeg = false,
                .scale => {
                    if (args_it.next()) |val| {
                        if (std.mem.eql(u8, val, "fit")) {
                            default_scale = .full;
                        } else if (std.mem.eql(u8, val, "fill")) {
                            default_scale = .crop;
                        } else if (std.mem.eql(u8, val, "1:1") or
                            std.mem.eql(u8, val, "actual"))
                        {
                            default_scale = .none;
                        } else if (std.meta.stringToEnum(ScaleMode, val)) |mode| {
                            default_scale = mode;
                        } else {
                            std.log.err(
                                "Unknown scale mode: {s}. Valid modes are: {s}.",
                                .{ val, intents.scale_modes_string },
                            );
                        }
                    } else {
                        std.log.err("Missing value for --scale flag.", .{});
                    }
                },
            }
        } else {
            // Treat non-flag arguments as path
            if (arg_path == null) {
                arg_path = try gpa.dupe(u8, arg);
            }
        }
    }

    return ParsedArgs{
        .arg_path = arg_path,
        .default_scale = default_scale,
        .test_mode = test_mode,
        .update_baselines = update_baselines,
        .headless = headless,
        .ipc_enabled = ipc_enabled,
        .enable_blur = enable_blur,
        .show_title = show_title,
        .windowless = windowless,
        .stack_raw_jpeg = stack_raw_jpeg,
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
    try testing.expect(std.mem.indexOf(u8, intents.scale_modes_string, "full") != null);
    try testing.expect(std.mem.indexOf(u8, intents.scale_modes_string, "fit_width") != null);
    try testing.expect(std.mem.indexOf(u8, intents.filter_modes_string, "mitchell") != null);
    try testing.expect(std.mem.indexOf(u8, intents.filter_modes_string, "lanczos3") != null);
    try testing.expect(std.mem.indexOf(u8, intents.filter_modes_string, "fsr") != null);
    try testing.expect(std.mem.indexOf(u8, intents.filter_modes_string, "tiny_cnn") != null);
}

test "help_text and ipc_help_text contain registered options" {
    const testing = std.testing;
    for (options) |opt| {
        if (opt.target.appliesTo(.main)) {
            try testing.expect(std.mem.indexOf(u8, main_help_text, opt.long) != null);
            if (opt.short) |s| {
                try testing.expect(std.mem.indexOf(u8, main_help_text, s) != null);
            }
        }
        if (opt.target.appliesTo(.ipc)) {
            try testing.expect(std.mem.indexOf(u8, ipc_help_text, opt.long) != null);
            if (opt.short) |s| {
                try testing.expect(std.mem.indexOf(u8, ipc_help_text, s) != null);
            }
        }
    }

    for (ipc_commands) |cmd| {
        try testing.expect(std.mem.indexOf(u8, ipc_help_text, cmd.name) != null);
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
        try testing.expectEqual(ScaleMode.crop, parsed.default_scale);
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
        try testing.expect(parsed.ipc_enabled);
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
        try testing.expect(parsed.ipc_enabled);
        try testing.expect(parsed.show_title);
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
