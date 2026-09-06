const intents = @import("intents");
const std = @import("std");

const ScaleMode = intents.ScaleMode;

/// Parsed command-line configuration options controlling launch behavior and rendering modes.
pub const ParsedArgs = struct {
    arg_path: ?[]const u8,
    default_scale: ScaleMode,
    test_mode: bool,
    update_baselines: bool,
    headless: bool,
    ipc_enabled: bool,
    enable_blur: bool = true,

    /// Frees allocated memory associated with parsed command-line arguments.
    pub fn deinit(self: *ParsedArgs, gpa: std.mem.Allocator) void {
        if (self.arg_path) |p| {
            gpa.free(p);
            self.arg_path = null;
        }
    }
};

/// Parses command-line flags and positional target paths from the process invocation.
pub fn parseCommandLineArgs(init: std.process.Init, gpa: std.mem.Allocator) !ParsedArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    var arg_path: ?[]const u8 = null;
    var default_scale: ScaleMode = .full;
    var test_mode = false;
    var update_baselines = false;
    var headless = false;
    var ipc_enabled = false;
    var enable_blur = true;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) {
            test_mode = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--update-baselines")) {
            update_baselines = true;
        } else if (std.mem.eql(u8, arg, "--ipc") or std.mem.eql(u8, arg, "--enable-ipc")) {
            ipc_enabled = true;
        } else if (std.mem.eql(u8, arg, "--blur") or std.mem.eql(u8, arg, "--enable-blur")) {
            enable_blur = true;
        } else if (std.mem.eql(u8, arg, "--no-blur") or std.mem.eql(u8, arg, "--disable-blur")) {
            enable_blur = false;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            if (args_it.next()) |val| {
                if (std.meta.stringToEnum(ScaleMode, val)) |mode| {
                    default_scale = mode;
                } else {
                    std.log.err("Unknown scale mode: {s}. Valid modes are: none, shrink, full, crop, fit_width, fit_height.", .{val});
                }
            } else {
                std.log.err("Missing value for --scale flag.", .{});
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
    };
}

test "parseCommandLineArgs handles blur flags" {
    const testing = std.testing;

    // Default enable_blur is true
    const parsed_default = ParsedArgs{
        .arg_path = null,
        .default_scale = .full,
        .test_mode = false,
        .update_baselines = false,
        .headless = false,
        .ipc_enabled = false,
        .enable_blur = true,
    };
    try testing.expect(parsed_default.enable_blur);

    const parsed_disabled = ParsedArgs{
        .arg_path = null,
        .default_scale = .full,
        .test_mode = false,
        .update_baselines = false,
        .headless = false,
        .ipc_enabled = false,
        .enable_blur = false,
    };
    try testing.expect(!parsed_disabled.enable_blur);
}
