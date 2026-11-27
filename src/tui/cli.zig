//! Command-Line Argument Parser for `peng-tui`
//!
//! Pure, zero-SDL CLI parser supporting terminal graphics protocol selection,
//! infobar placement, scaling/filter presets, slideshow interval, RAW+JPEG
//! stacking toggle, and optional debug log file redirection.

const canvas = @import("canvas.zig");
const intents = @import("intents");
const state = @import("state");
const std = @import("std");
const termgfx = @import("termgfx");
const thumbcache = @import("thumbcache");

const InfobarPosition = canvas.InfobarPosition;
const ProtocolMode = termgfx.ProtocolMode;
const SlideshowMode = state.SlideshowMode;
const TextureScaleMode = intents.TextureScaleMode;
const ThumbCacheMode = thumbcache.ThumbCacheMode;
const ZoomPreset = intents.ZoomPreset;

/// Parsed command-line options for `peng-tui`.
pub const TuiCliArgs = struct {
    path: ?[]const u8 = null,
    protocol: ProtocolMode = .auto,
    infobar: InfobarPosition = .bottom,
    default_scale: ZoomPreset = .full,
    scale_filter: TextureScaleMode = .linear,
    slideshow_interval_s: ?f32 = null,
    stack_raw_jpeg: bool = true,
    thumb_cache: ThumbCacheMode = .all,
    log_file: ?[]const u8 = null,
    help: bool = false,

    /// Releases owned `path` and `log_file` strings allocated by `parseArgs`.
    pub fn deinit(self: *TuiCliArgs, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        if (self.log_file) |lf| allocator.free(lf);
        self.path = null;
        self.log_file = null;
    }
};

/// Parses an infobar placement string (`bottom`, `top`, `none`).
pub fn parseInfobarPosition(str: []const u8) ?InfobarPosition {
    if (std.ascii.eqlIgnoreCase(str, "bottom")) return .bottom;
    if (std.ascii.eqlIgnoreCase(str, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(str, "none")) return .none;
    return null;
}

/// Parses a slice of CLI arguments (excluding `argv[0]`) into `TuiCliArgs`.
/// Owned strings (`path`, `log_file`) are duplicated with `allocator`.
pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !TuiCliArgs {
    var result: TuiCliArgs = .{};
    errdefer result.deinit(allocator);

    var positional_only = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only) {
            if (result.path == null) {
                result.path = try allocator.dupe(u8, arg);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
        } else if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            result.help = true;
            return result;
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.protocol = ProtocolMode.parse(args[i]) orelse
                return error.InvalidProtocol;
        } else if (std.mem.eql(u8, arg, "--infobar")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.infobar = parseInfobarPosition(args[i]) orelse
                return error.InvalidInfobar;
        } else if (std.mem.eql(u8, arg, "-s") or
            std.mem.eql(u8, arg, "--scale"))
        {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.default_scale = ZoomPreset.parse(args[i]) orelse
                return error.InvalidScale;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.scale_filter = std.meta.stringToEnum(
                TextureScaleMode,
                args[i],
            ) orelse return error.InvalidFilter;
        } else if (std.mem.eql(u8, arg, "--slideshow")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            const secs = std.fmt.parseFloat(f32, args[i]) catch
                return error.InvalidSlideshowInterval;
            if (!std.math.isFinite(secs) or
                secs < SlideshowMode.MIN_INTERVAL_S or
                secs > SlideshowMode.MAX_INTERVAL_S)
            {
                return error.InvalidSlideshowInterval;
            }
            result.slideshow_interval_s = secs;
        } else if (std.mem.eql(u8, arg, "--stack-raw-jpeg")) {
            result.stack_raw_jpeg = true;
        } else if (std.mem.eql(u8, arg, "--no-stack-raw-jpeg")) {
            result.stack_raw_jpeg = false;
        } else if (std.mem.eql(u8, arg, "--thumb-cache")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.thumb_cache = ThumbCacheMode.parse(args[i]) orelse
                return error.InvalidThumbCacheMode;
        } else if (std.mem.eql(u8, arg, "--no-thumb-cache")) {
            result.thumb_cache = .off;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            const next = try allocator.dupe(u8, args[i]);
            if (result.log_file) |old| allocator.free(old);
            result.log_file = next;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (result.path == null) {
            result.path = try allocator.dupe(u8, arg);
        }
    }
    return result;
}

/// Prints `peng-tui` CLI usage documentation to standard output.
pub fn printHelp(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(
        \\Usage: peng-tui [OPTIONS] [PATH]
        \\
        \\GPU-accelerated terminal image viewer and photo triage tool.
        \\On exit, any Pick/Reject classifications are printed as TSV to stdout.
        \\
        \\Options:
        \\  --protocol <MODE>      Terminal graphics protocol (default: auto):
        \\                         {s}
        \\  --infobar <bottom|top|none>
        \\                         Infobar placement (default: bottom)
        \\  -s, --scale <fit|fill|shrink|1:1|width|height>
        \\                         Default image scale mode (default: fit)
        \\  --filter <nearest|linear|pixel_art|mitchell|lanczos3|fsr|tiny_cnn>
        \\                         GPU resampling filter (default: linear)
        \\  --slideshow <SECONDS>  Start slideshow with interval in seconds
        \\  --stack-raw-jpeg       Group RAW and companion JPEG files (default)
        \\  --no-stack-raw-jpeg    Display RAW and companion JPEG separately
        \\  --thumb-cache <MODE>   Thumb cache (all, missing, read_only, off)
        \\  --no-thumb-cache       Disable XDG shared thumbnail cache
        \\  --log-file <PATH>      Write debug logs to a file instead of muting
        \\  -h, --help             Show this help message
        \\
    , .{termgfx.protocolModesString(environ_map)}) catch {};
    w.interface.flush() catch {};
}

test "parseArgs parses all flags and positional path" {
    const allocator = std.testing.allocator;
    const raw = [_][]const u8{
        "--protocol",
        "halfblocks",
        "--infobar",
        "top",
        "-s",
        "fill",
        "--filter",
        "lanczos3",
        "--slideshow",
        "2.5",
        "--no-stack-raw-jpeg",
        "--thumb-cache",
        "read_only",
        "--log-file",
        "/tmp/peng-tui.log",
        "testfiles/images/",
    };
    var parsed = try parseArgs(allocator, &raw);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(ProtocolMode.halfblocks, parsed.protocol);
    try std.testing.expectEqual(InfobarPosition.top, parsed.infobar);
    try std.testing.expectEqual(ZoomPreset.crop, parsed.default_scale);
    try std.testing.expectEqual(
        TextureScaleMode.lanczos3,
        parsed.scale_filter,
    );
    try std.testing.expectEqual(@as(?f32, 2.5), parsed.slideshow_interval_s);
    try std.testing.expect(!parsed.stack_raw_jpeg);
    try std.testing.expectEqual(ThumbCacheMode.read_only, parsed.thumb_cache);
    try std.testing.expectEqualStrings("/tmp/peng-tui.log", parsed.log_file.?);
    try std.testing.expectEqualStrings("testfiles/images/", parsed.path.?);
}

test "parseArgs rejects invalid flag values without leaking" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidProtocol,
        parseArgs(allocator, &.{ "--protocol", "bogus" }),
    );
    try std.testing.expectError(
        error.InvalidScale,
        parseArgs(allocator, &.{ "--scale", "bogus" }),
    );
    try std.testing.expectError(
        error.InvalidFilter,
        parseArgs(allocator, &.{ "--filter", "bogus" }),
    );
    try std.testing.expectError(
        error.InvalidSlideshowInterval,
        parseArgs(allocator, &.{ "--slideshow", "0" }),
    );
    try std.testing.expectError(
        error.MissingArgument,
        parseArgs(allocator, &.{"--log-file"}),
    );
    try std.testing.expectError(
        error.UnknownFlag,
        parseArgs(allocator, &.{ "testfiles/images/", "--nope" }),
    );
    try std.testing.expectError(
        error.InvalidInfobar,
        parseArgs(allocator, &.{ "--infobar", "left" }),
    );
    try std.testing.expectError(
        error.InvalidSlideshowInterval,
        parseArgs(allocator, &.{ "--slideshow", "nan" }),
    );
    try std.testing.expectError(
        error.InvalidSlideshowInterval,
        parseArgs(allocator, &.{ "--slideshow", "inf" }),
    );
    try std.testing.expectError(
        error.InvalidSlideshowInterval,
        parseArgs(allocator, &.{ "--slideshow", "9999" }),
    );
    try std.testing.expectError(
        error.InvalidThumbCacheMode,
        parseArgs(allocator, &.{ "--thumb-cache", "bogus" }),
    );
}

test "parseArgs defaults, help, case-insensitive infobar, and OOM safety" {
    const allocator = std.testing.allocator;

    var defaults = try parseArgs(allocator, &.{});
    defer defaults.deinit(allocator);
    try std.testing.expect(!defaults.help);
    try std.testing.expectEqual(ProtocolMode.auto, defaults.protocol);
    try std.testing.expectEqual(InfobarPosition.bottom, defaults.infobar);
    try std.testing.expectEqual(ZoomPreset.full, defaults.default_scale);
    try std.testing.expectEqual(
        TextureScaleMode.linear,
        defaults.scale_filter,
    );
    try std.testing.expect(defaults.stack_raw_jpeg);
    try std.testing.expectEqual(ThumbCacheMode.all, defaults.thumb_cache);
    try std.testing.expect(defaults.path == null);
    try std.testing.expect(defaults.log_file == null);

    try std.testing.expectEqual(
        @as(?InfobarPosition, .top),
        parseInfobarPosition("TOP"),
    );

    var help_parsed = try parseArgs(
        allocator,
        &.{ "--log-file", "/tmp/a.log", "-h" },
    );
    defer help_parsed.deinit(allocator);
    try std.testing.expect(help_parsed.help);

    const dup_args = [_][]const u8{
        "--log-file",
        "/tmp/first.log",
        "--log-file",
        "/tmp/second.log",
        "testfiles/images/",
    };
    const Runner = struct {
        fn run(a: std.mem.Allocator) !void {
            var p = try parseArgs(a, &dup_args);
            defer p.deinit(a);
            try std.testing.expectEqualStrings("/tmp/second.log", p.log_file.?);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Runner.run, .{});
}

test "parseArgs supports -- end-of-options separator" {
    const allocator = std.testing.allocator;

    var dash_file = try parseArgs(
        allocator,
        &.{ "--protocol", "sixel", "--", "-weird-name.jpg" },
    );
    defer dash_file.deinit(allocator);
    try std.testing.expectEqual(ProtocolMode.sixel, dash_file.protocol);
    try std.testing.expect(!dash_file.help);
    try std.testing.expectEqualStrings("-weird-name.jpg", dash_file.path.?);

    var dash_help = try parseArgs(allocator, &.{ "--", "--help" });
    defer dash_help.deinit(allocator);
    try std.testing.expect(!dash_help.help);
    try std.testing.expectEqualStrings("--help", dash_help.path.?);

    var trailing = try parseArgs(allocator, &.{ "--infobar", "none", "--" });
    defer trailing.deinit(allocator);
    try std.testing.expectEqual(InfobarPosition.none, trailing.infobar);
    try std.testing.expect(trailing.path == null);
}
