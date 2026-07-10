const std = @import("std");
const main = @import("../main.zig");
const ScaleMode = main.ScaleMode;

pub const ParsedArgs = struct {
    arg_path: ?[]const u8,
    default_scale: ScaleMode,
    test_mode: bool,
    update_baselines: bool,
};

pub fn parseCommandLineArgs(init: std.process.Init, gpa: std.mem.Allocator) !ParsedArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    var arg_path: ?[]const u8 = null;
    var default_scale: ScaleMode = .full;
    var test_mode = false;
    var update_baselines = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) {
            test_mode = true;
        } else if (std.mem.eql(u8, arg, "--update-baselines")) {
            update_baselines = true;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            if (args_it.next()) |val| {
                if (std.mem.eql(u8, val, "none")) {
                    default_scale = .none;
                } else if (std.mem.eql(u8, val, "shrink")) {
                    default_scale = .shrink;
                } else if (std.mem.eql(u8, val, "full")) {
                    default_scale = .full;
                } else if (std.mem.eql(u8, val, "crop")) {
                    default_scale = .crop;
                } else {
                    std.log.err("Unknown scale mode: {s}. Valid modes are: none, shrink, full, crop.", .{val});
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
    };
}
