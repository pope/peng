const intents = @import("intents");
const std = @import("std");

const ScaleMode = intents.ScaleMode;
const TextureScaleMode = intents.TextureScaleMode;

/// Target application scope for a command-line option or command.
pub const CliTarget = enum {
    main,
    ipc,
    both,

    /// Returns true if this target applies to the given scope.
    pub fn appliesTo(self: CliTarget, scope: CliTarget) bool {
        if (self == .both or scope == .both) return true;
        return self == scope;
    }
};

/// Enumeration of distinct command-line option identifiers.
pub const OptionId = enum {
    help,
    scale,
    blur,
    no_blur,
    ipc,
    headless,
    test_mode,
    update_baselines,
};

/// Declarative schema describing a command-line option, its target app, aliases, placeholder, and description.
pub const CliOption = struct {
    id: OptionId,
    target: CliTarget = .both,
    short: ?[]const u8 = null,
    long: []const u8,
    aliases: []const []const u8 = &.{},
    arg_name: ?[]const u8 = null,
    description: []const u8,

    /// Returns true if the given argument matches this option's short flag, long flag, or any alias.
    pub fn matches(self: CliOption, arg: []const u8) bool {
        if (self.short) |s| {
            if (std.mem.eql(u8, arg, s)) return true;
        }
        if (std.mem.eql(u8, arg, self.long)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, arg, alias)) return true;
        }
        return false;
    }
};

/// Comptime-generated comma-separated list of all valid ScaleMode names via reflection.
pub const scale_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const fields = @typeInfo(ScaleMode).@"enum".fields;
    for (fields, 0..) |field, i| {
        str = if (i > 0) str ++ ", " ++ field.name else field.name;
    }
    break :blk str;
};

/// Comptime-generated comma-separated list of all valid TextureScaleMode names via reflection.
pub const filter_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const fields = @typeInfo(TextureScaleMode).@"enum".fields;
    for (fields, 0..) |field, i| {
        str = if (i > 0) str ++ ", " ++ field.name else field.name;
    }
    break :blk str;
};

/// Centralized declarative registry of all supported command-line options.
pub const options = [_]CliOption{
    .{
        .id = .help,
        .target = .both,
        .short = "-h",
        .long = "--help",
        .description = "Show this help message and exit",
    },
    .{
        .id = .scale,
        .target = .main,
        .long = "--scale",
        .arg_name = "<mode>",
        .description = "Default image scaling mode (default: full)\n                             Modes: " ++ scale_modes_string,
    },
    .{
        .id = .blur,
        .target = .main,
        .long = "--blur",
        .aliases = &.{"--enable-blur"},
        .description = "Enable glassmorphism background blur behind overlays (default)",
    },
    .{
        .id = .no_blur,
        .target = .main,
        .long = "--no-blur",
        .aliases = &.{"--disable-blur"},
        .description = "Disable glassmorphism background blur behind overlays",
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

/// Declarative schema describing an IPC message command word and its usage.
pub const IpcCommandDesc = struct {
    name: []const u8,
    args: ?[]const u8 = null,
    description: []const u8,
};

/// Centralized declarative registry of common IPC control commands.
pub const ipc_commands = [_]IpcCommandDesc{
    .{ .name = "zoom", .args = "<factor>", .description = "Set zoom factor (0.1 - 10.0)" },
    .{ .name = "pan", .args = "<x> <y>", .description = "Set pan offset in pixels" },
    .{ .name = "scale", .args = "<mode>", .description = "Set fit mode (" ++ scale_modes_string ++ ")" },
    .{ .name = "manga", .args = "<true|false>", .description = "Toggle RTL manga reading mode" },
    .{ .name = "adjust", .args = "<bright> <contrast>", .description = "Adjust brightness and contrast" },
    .{ .name = "filter", .args = "<name>", .description = "Apply resampling shader (" ++ filter_modes_string ++ ")" },
    .{ .name = "next / prev", .description = "Navigate images" },
    .{ .name = "palette", .args = "<action|files|none>", .description = "Toggle command/file palette" },
    .{ .name = "thumb", .args = "<toggle|true|false>", .description = "Toggle embedded thumbnail preview" },
    .{ .name = "debug", .args = "<true|false>", .description = "Toggle Clay UI layout debug borders" },
    .{ .name = "wait_load", .description = "Wait for image decoding to complete" },
    .{ .name = "quit", .description = "Quit the viewer" },
};

/// Finds a registered CliOption matching the provided argument string across all targets.
pub fn findOption(arg: []const u8) ?CliOption {
    for (options) |opt| {
        if (opt.matches(arg)) return opt;
    }
    return null;
}

/// Finds a registered CliOption matching the provided argument string for a specific target scope.
pub fn findOptionFor(arg: []const u8, scope: CliTarget) ?CliOption {
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
pub fn formatOptionFlags(comptime opt: CliOption) []const u8 {
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
pub fn formatOptionsFor(comptime target: CliTarget, comptime col_width: usize) []const u8 {
    var text: []const u8 = "";
    for (options) |opt| {
        if (!opt.target.appliesTo(target)) continue;
        const col = padRight(formatOptionFlags(opt), col_width);
        text = text ++ col ++ opt.description ++ "\n";
    }
    return text;
}

/// Formats the IPC command list with aligned descriptions.
pub fn formatIpcCommands(comptime col_width: usize) []const u8 {
    var text: []const u8 = "";
    for (ipc_commands) |cmd| {
        var col: []const u8 = "  " ++ cmd.name;
        if (cmd.args) |arg| {
            col = col ++ " " ++ arg;
        }
        text = text ++ padRight(col, col_width) ++ cmd.description ++ "\n";
    }
    return text;
}

/// Specification for generating a standardized, formatted application help message.
pub const HelpSpec = struct {
    title: []const u8,
    usage: []const u8,
    arguments: ?[]const u8 = null,
    target: CliTarget,
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

/// Formatted application help text dynamically generated for the primary `peng` viewer at compile-time.
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
                .scale => {
                    if (args_it.next()) |val| {
                        if (std.meta.stringToEnum(ScaleMode, val)) |mode| {
                            default_scale = mode;
                        } else {
                            std.log.err("Unknown scale mode: {s}. Valid modes are: {s}.", .{ val, scale_modes_string });
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
    try testing.expect(CliTarget.both.appliesTo(.main));
    try testing.expect(CliTarget.both.appliesTo(.ipc));
    try testing.expect(CliTarget.both.appliesTo(.both));

    try testing.expect(CliTarget.main.appliesTo(.main));
    try testing.expect(!CliTarget.main.appliesTo(.ipc));
    try testing.expect(CliTarget.main.appliesTo(.both));

    try testing.expect(!CliTarget.ipc.appliesTo(.main));
    try testing.expect(CliTarget.ipc.appliesTo(.ipc));
    try testing.expect(CliTarget.ipc.appliesTo(.both));
}

test "scale_modes_string and filter_modes_string contain enum variants" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, scale_modes_string, "full") != null);
    try testing.expect(std.mem.indexOf(u8, scale_modes_string, "fit_width") != null);
    try testing.expect(std.mem.indexOf(u8, filter_modes_string, "mitchell") != null);
    try testing.expect(std.mem.indexOf(u8, filter_modes_string, "lanczos3") != null);
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

test "findOption and findOptionFor respect target filtering" {
    const testing = std.testing;

    try testing.expectEqual(OptionId.help, findOption("-h").?.id);
    try testing.expectEqual(OptionId.help, findOptionFor("-h", .main).?.id);
    try testing.expectEqual(OptionId.help, findOptionFor("-h", .ipc).?.id);

    try testing.expectEqual(OptionId.scale, findOptionFor("--scale", .main).?.id);
    try testing.expect(findOptionFor("--scale", .ipc) == null);

    try testing.expectEqual(OptionId.ipc, findOptionFor("--ipc", .main).?.id);
    try testing.expect(findOptionFor("--ipc", .ipc) == null);

    try testing.expect(findOption("--unknown") == null);
    try testing.expect(findOption("photo.jpg") == null);
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
        var it = SliceIterator{ .slice = &[_][]const u8{ "--no-blur", "--ipc", "--headless", "--test-mode" } };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.enable_blur);
        try testing.expect(parsed.ipc_enabled);
        try testing.expect(parsed.headless);
        try testing.expect(parsed.test_mode);
        try testing.expect(!parsed.help);
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{ "--disable-blur", "--enable-ipc" } };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(!parsed.enable_blur);
        try testing.expect(parsed.ipc_enabled);
    }

    {
        var it = SliceIterator{ .slice = &[_][]const u8{ "--enable-blur", "--blur" } };
        var parsed = try parseArgsIterator(&it, testing.allocator);
        defer parsed.deinit(testing.allocator);
        try testing.expect(parsed.enable_blur);
    }
}
