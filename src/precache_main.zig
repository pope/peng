const app_config = @import("config");
const core = @import("core");
const sdl = @import("sdl");
const std = @import("std");
const thumbcache = @import("thumbcache");

const collectPrecacheFiles = thumbcache.collectPrecacheFiles;
const encodeBytesToThumbnailPng = core.thumbcache.encodeBytesToThumbnailPng;
const precachePathsParallel = thumbcache.precachePathsParallel;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbTier = thumbcache.ThumbTier;
const ThumbWritePolicy = thumbcache.ThumbWritePolicy;

fn resolveWriteTier(override_opt: ?ThumbTier) ThumbTier {
    if (override_opt) |tier| return tier;
    if (!sdl.init(sdl.init_flags.video)) return .normal;
    defer sdl.quit();
    const scale = sdl.getPrimaryDisplayContentScale() orelse return .normal;
    return ThumbTier.fromDpiScale(scale);
}

/// Standalone CLI entry point for parallel Freedesktop thumbnail pre-caching
/// (`peng-precache [options] [path]`).
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var parsed = app_config.cli.parsePrecacheArgs(init, gpa) catch {
        std.process.exit(1);
    };
    defer parsed.deinit(gpa);

    if (parsed.help) {
        app_config.cli.printPrecacheHelp(io);
        return;
    }

    const policy: ThumbWritePolicy = switch (parsed.thumb_cache) {
        .all => .all_missing,
        .missing => .missing_embedded_only,
        .read_only, .off => {
            std.log.err(
                "peng-precache requires a writable --thumb-cache mode " ++
                    "(all or missing).",
                .{},
            );
            std.process.exit(1);
        },
    };
    const write_tier = resolveWriteTier(parsed.thumb_size);
    var cfg = ThumbCacheConfig.initFromEnviron(
        gpa,
        init.environ_map,
        policy,
        write_tier,
    );
    defer cfg.deinit(gpa);

    const enabled_cfg = switch (cfg) {
        .enabled => |c| c,
        .disabled => {
            std.log.err(
                "Freedesktop thumbnail cache unavailable " ++
                    "(check HOME / XDG_CACHE_HOME)",
                .{},
            );
            std.process.exit(1);
        },
    };

    const target_path = parsed.path orelse ".";
    var path_arena: std.heap.ArenaAllocator = .init(gpa);
    defer path_arena.deinit();
    const path_alloc = path_arena.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    collectPrecacheFiles(
        path_alloc,
        io,
        target_path,
        parsed.recursive,
        &files,
    ) catch |err| {
        std.log.err(
            "Failed to collect files from '{s}': {s}",
            .{ target_path, @errorName(err) },
        );
        std.process.exit(1);
    };

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const max_workers = @max(@as(usize, 1), @min(@as(usize, 8), cpu_count));
    const stats = precachePathsParallel(
        gpa,
        io,
        enabled_cfg,
        files.items,
        max_workers,
        .{},
        encodeBytesToThumbnailPng,
    );

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_writer.interface.print(
        "Pre-cached {s}: {d} written, {d} already cached, " ++
            "{d} skipped, {d} failed ({d} total)\n",
        .{
            target_path,
            stats.written,
            stats.already_valid,
            stats.skipped,
            stats.failed,
            stats.total_files,
        },
    ) catch |err| {
        std.log.warn("Failed to write precache summary: {}", .{err});
        return;
    };
    stdout_writer.interface.flush() catch |err| {
        std.log.warn("Failed to flush precache summary: {}", .{err});
    };
}
