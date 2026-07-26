const std = @import("std");

/// Represents a dependency parsed from a `build.zig.zon` manifest file.
pub const Dependency = struct {
    /// Dependency key name as defined in `build.zig.zon` (e.g., "zclay").
    key: []const u8,
    /// Source URL for fetching the dependency (archive URL or `git+https://...`).
    url: []const u8,
    /// Multihash string defined in the manifest for verification.
    hash: []const u8,
    /// Indicates whether the dependency is marked lazy.
    lazy: bool = false,
};

/// Represents an evaluated dependency entry formatted into the generated `nix/deps.nix` file.
pub const NixEntry = struct {
    /// Multihash string matching `build.zig.zon`.
    zon_hash: []const u8,
    /// Original package source URL.
    url: []const u8,
    /// Calculated Subresource Integrity (SRI) hash string (`sha256-...`).
    sri_hash: []const u8,
    /// Indicates whether the source is a Git repository.
    is_git: bool,
    /// Cleaned repository URL for `fetchgit`.
    repo_url: []const u8,
    /// Specific revision or commit SHA for `fetchgit`.
    rev: []const u8,
};

/// Represents parsed Git repository URL components.
pub const GitUrl = struct {
    /// True if the URL scheme starts with `git+`.
    is_git: bool,
    /// Base HTTP/HTTPS URL of the Git repository.
    repo_url: []const u8,
    /// Target revision or commit hash extracted from `#rev`.
    rev: []const u8,
};

/// Result of checking whether a package or its ZON manifest is cached on disk.
pub const CacheCheckResult = union(enum) {
    /// Package is cached and contains a valid `build.zig.zon` manifest at the specified path.
    zon_found: []const u8,
    /// Package directory is cached locally, but does not contain a `build.zig.zon` manifest (e.g., pure C library).
    package_cached_no_zon: []const u8,
    /// Package is not cached in any known local or global cache directories.
    not_cached,
};

/// Parses a dependency URL to determine if it is a Git repository, returning the base repository URL and target revision.
pub fn parseGitUrl(allocator: std.mem.Allocator, url: []const u8) !GitUrl {
    if (std.mem.startsWith(u8, url, "git+")) {
        const raw_git = url[4..];
        var base_url = raw_git;
        var rev: []const u8 = "";

        if (std.mem.indexOfScalar(u8, raw_git, '#')) |hash_pos| {
            base_url = raw_git[0..hash_pos];
            rev = raw_git[hash_pos + 1 ..];
        }
        if (std.mem.indexOfScalar(u8, base_url, '?')) |q_pos| {
            base_url = base_url[0..q_pos];
        }

        return .{
            .is_git = true,
            .repo_url = try allocator.dupe(u8, base_url),
            .rev = try allocator.dupe(u8, rev),
        };
    }

    return .{
        .is_git = false,
        .repo_url = try allocator.dupe(u8, ""),
        .rev = try allocator.dupe(u8, ""),
    };
}

/// Parses a `build.zig.zon` file using Zig's AST parser and ZOIR generator to extract direct dependency declarations.
pub fn parseZonDependencies(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.ArrayList(Dependency) {
    var deps = std.ArrayList(Dependency).empty;
    errdefer {
        for (deps.items) |d| {
            allocator.free(d.key);
            allocator.free(d.url);
            allocator.free(d.hash);
        }
        deps.deinit(allocator);
    }

    const file_contents = try std.Io.Dir.readFileAllocOptions(
        std.Io.Dir.cwd(),
        io,
        path,
        allocator,
        @enumFromInt(1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(file_contents);

    var ast = try std.zig.Ast.parse(allocator, file_contents, .zon);
    defer ast.deinit(allocator);

    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(allocator);

    const root_node = std.zig.Zoir.Node.Index.root.get(zoir);
    switch (root_node) {
        .struct_literal => |s| {
            for (s.names, 0..) |name_nts, i| {
                const field_name = name_nts.get(zoir);
                if (std.mem.eql(u8, field_name, "dependencies")) {
                    const deps_val_idx: std.zig.Zoir.Node.Index = @enumFromInt(@intFromEnum(s.vals.start) + i);
                    switch (deps_val_idx.get(zoir)) {
                        .struct_literal => |deps_struct| {
                            for (deps_struct.names, 0..) |dep_nts, j| {
                                const dep_key_raw = dep_nts.get(zoir);
                                const dep_key = try allocator.dupe(u8, dep_key_raw);
                                errdefer allocator.free(dep_key);

                                const dep_val_idx: std.zig.Zoir.Node.Index = @enumFromInt(@intFromEnum(deps_struct.vals.start) + j);

                                var url_opt: ?[]const u8 = null;
                                var hash_opt: ?[]const u8 = null;
                                var is_lazy = false;

                                switch (dep_val_idx.get(zoir)) {
                                    .struct_literal => |df| {
                                        for (df.names, 0..) |fn_nts, k| {
                                            const fn_name = fn_nts.get(zoir);
                                            const fv_idx: std.zig.Zoir.Node.Index = @enumFromInt(@intFromEnum(df.vals.start) + k);
                                            const fv_node = fv_idx.get(zoir);

                                            if (std.mem.eql(u8, fn_name, "url")) {
                                                switch (fv_node) {
                                                    .string_literal => |u| url_opt = try allocator.dupe(u8, u),
                                                    else => {},
                                                }
                                            } else if (std.mem.eql(u8, fn_name, "hash")) {
                                                switch (fv_node) {
                                                    .string_literal => |h| hash_opt = try allocator.dupe(u8, h),
                                                    else => {},
                                                }
                                            } else if (std.mem.eql(u8, fn_name, "lazy")) {
                                                switch (fv_node) {
                                                    .true => is_lazy = true,
                                                    else => {},
                                                }
                                            }
                                        }
                                    },
                                    else => {},
                                }

                                if (url_opt) |u| {
                                    if (hash_opt) |h| {
                                        try deps.append(allocator, .{
                                            .key = dep_key,
                                            .url = u,
                                            .hash = h,
                                            .lazy = is_lazy,
                                        });
                                        continue;
                                    }
                                }
                                allocator.free(dep_key);
                                if (url_opt) |u| allocator.free(u);
                                if (hash_opt) |h| allocator.free(h);
                            }
                        },
                        else => {},
                    }
                }
            }
        },
        else => {},
    }

    return deps;
}

/// Downloads raw binary data from an HTTP or HTTPS URL using standard `std.http.Client`.
fn fetchUrlBytes(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var array_list = std.ArrayList(u8).empty;
    errdefer array_list.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &array_list);

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    if (res.status != .ok) {
        std.log.err("HTTP fetch returned non-OK status {s} for '{s}'", .{ @tagName(res.status), url });
        return error.HttpError;
    }
    var al = aw.toArrayList();
    return al.toOwnedSlice(allocator);
}

/// Invokes `nix-prefetch-git` to calculate the SRI hash for a Git repository revision.
fn prefetchGitHash(allocator: std.mem.Allocator, io: std.Io, repo_url: []const u8, rev: []const u8) ![]const u8 {
    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "nix-prefetch-git", "--quiet", repo_url, rev },
        .expand_arg0 = .expand,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.log.err("nix-prefetch-git exited with status {any} for '{s}': {s}", .{ res.term, repo_url, res.stderr });
        return error.PrefetchGitFailed;
    }

    const JsonHash = struct { hash: ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(JsonHash, allocator, res.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.hash) |h| {
        return try allocator.dupe(u8, h);
    }
    return error.MissingHashInJson;
}

/// Invokes `nix store prefetch-file --unpack --json` to calculate the SRI hash for an archive URL.
fn prefetchUrlHash(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "nix", "store", "prefetch-file", "--unpack", "--json", url },
        .expand_arg0 = .expand,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.log.err("nix store prefetch-file exited with status {any} for '{s}': {s}", .{ res.term, url, res.stderr });
        return error.PrefetchUrlFailed;
    }

    const JsonHash = struct { hash: ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(JsonHash, allocator, res.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.hash) |h| {
        return try allocator.dupe(u8, h);
    }
    return error.MissingHashInJson;
}

/// Searches an existing `nix/deps.nix` file for a previously calculated SRI hash matching the specified ZON multihash.
fn lookupExistingHash(allocator: std.mem.Allocator, io: std.Io, nix_deps_path: []const u8, zon_hash: []const u8) !?[]const u8 {
    const file_contents = std.Io.Dir.readFileAllocOptions(
        std.Io.Dir.cwd(),
        io,
        nix_deps_path,
        allocator,
        @enumFromInt(1024 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(file_contents);

    var lines = std.mem.splitScalar(u8, file_contents, '\n');
    var found_name = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, zon_hash) != null) {
            found_name = true;
            continue;
        }
        if (found_name) {
            if (std.mem.indexOf(u8, line, "hash =")) |hash_idx| {
                const quote_start = std.mem.indexOfPos(u8, line, hash_idx + 6, "\"") orelse continue;
                const quote_end = std.mem.indexOfPos(u8, line, quote_start + 1, "\"") orelse continue;
                const extracted = line[quote_start + 1 .. quote_end];
                return try allocator.dupe(u8, extracted);
            }
            if (std.mem.indexOf(u8, line, "};") != null) {
                found_name = false;
            }
        }
    }
    return null;
}

/// Checks local and global Zig package cache directories (`zig-pkg/`, `.zig-cache/p/`, `~/.cache/zig/p/`) for cached package files.
fn checkCachedPackage(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, dep_hash: []const u8) !CacheCheckResult {
    var bases = std.ArrayList([]const u8).empty;
    defer {
        for (bases.items) |b| allocator.free(b);
        bases.deinit(allocator);
    }

    try bases.append(allocator, try allocator.dupe(u8, "zig-pkg"));
    try bases.append(allocator, try allocator.dupe(u8, ".zig-cache/p"));

    if (environ_map.get("HOME")) |home| {
        try bases.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.cache/zig/p", .{home}));
    }

    for (bases.items) |base_path| {
        const direct_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, dep_hash });
        defer allocator.free(direct_dir);

        if (std.Io.Dir.cwd().statFile(io, direct_dir, .{})) |stat| {
            if (stat.kind == .directory) {
                const zon_file = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{direct_dir});
                errdefer allocator.free(zon_file);

                if (std.Io.Dir.cwd().openFile(io, zon_file, .{})) |f| {
                    f.close(io);
                    return .{ .zon_found = zon_file };
                } else |err| switch (err) {
                    error.FileNotFound => {
                        allocator.free(zon_file);
                        return .{ .package_cached_no_zon = try allocator.dupe(u8, direct_dir) };
                    },
                    else => return err,
                }
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and std.mem.indexOf(u8, entry.name, dep_hash) != null) {
                const matched_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, entry.name });
                defer allocator.free(matched_dir);

                const zon_file = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{matched_dir});
                errdefer allocator.free(zon_file);

                if (std.Io.Dir.cwd().openFile(io, zon_file, .{})) |f| {
                    f.close(io);
                    return .{ .zon_found = zon_file };
                } else |err| switch (err) {
                    error.FileNotFound => {
                        allocator.free(zon_file);
                        return .{ .package_cached_no_zon = try allocator.dupe(u8, matched_dir) };
                    },
                    else => return err,
                }
            }
        }
    }

    return .not_cached;
}

/// Downloads or clones a package archive/repository to a temporary path, extracts its contents, and searches for a nested `build.zig.zon` for transitive dependency resolution.
fn fetchAndExtractZon(
    allocator: std.mem.Allocator,
    io: std.Io,
    dep: Dependency,
    git_info: GitUrl,
    tmp_count: usize,
) !?[]const u8 {
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/zon_dep_{}", .{tmp_count});
    defer allocator.free(tmp_path);

    if (git_info.is_git) {
        std.log.info("cache miss for '{s}', cloning git repository '{s}'...", .{ dep.key, git_info.repo_url });
        try std.Io.Dir.cwd().deleteTree(io, tmp_path);

        const clone_res = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "clone", "--quiet", "--depth", "1", git_info.repo_url, tmp_path },
            .expand_arg0 = .expand,
        });
        defer allocator.free(clone_res.stdout);
        defer allocator.free(clone_res.stderr);

        if (clone_res.term != .exited or clone_res.term.exited != 0) {
            std.log.err("git clone process failed with status {any} for '{s}': {s}", .{ clone_res.term, git_info.repo_url, clone_res.stderr });
            return error.GitCloneFailed;
        }

        const nested_zon = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{tmp_path});
        if (std.Io.Dir.cwd().openFile(io, nested_zon, .{})) |f| {
            f.close(io);
            return nested_zon;
        } else |err| switch (err) {
            error.FileNotFound => {
                allocator.free(nested_zon);
                return null;
            },
            else => return err,
        }
    } else {
        std.log.info("cache miss for '{s}', downloading archive '{s}'...", .{ dep.key, dep.url });
        const archive_bytes = try fetchUrlBytes(allocator, io, dep.url);
        defer allocator.free(archive_bytes);

        const archive_path = try std.fmt.allocPrint(allocator, "/tmp/zon_arc_{}.pkg", .{tmp_count});
        defer allocator.free(archive_path);
        defer {
            std.Io.Dir.cwd().deleteFile(io, archive_path) catch |err| {
                if (err != error.FileNotFound) {
                    std.log.warn("failed to clean up temporary archive '{s}': {any}", .{ archive_path, err });
                }
            };
        }

        var arc_file = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        var write_buf: [4096]u8 = undefined;
        var arc_fw = arc_file.writer(io, &write_buf);
        try arc_fw.interface.writeAll(archive_bytes);
        try arc_fw.flush();
        arc_file.close(io);

        try std.Io.Dir.cwd().deleteTree(io, tmp_path);
        try std.Io.Dir.cwd().createDirPath(io, tmp_path);
        var dest_dir = try std.Io.Dir.cwd().openDir(io, tmp_path, .{ .iterate = true });
        defer dest_dir.close(io);

        var read_buf: [4096]u8 = undefined;

        if (std.mem.endsWith(u8, dep.url, ".zip")) {
            var open_zip = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
            defer open_zip.close(io);

            var zip_reader = open_zip.reader(io, &read_buf);
            try std.zip.extract(dest_dir, &zip_reader, .{});
        } else if (std.mem.endsWith(u8, dep.url, ".tar.gz") or std.mem.endsWith(u8, dep.url, ".tgz")) {
            var open_tar = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
            defer open_tar.close(io);

            var tar_reader = open_tar.reader(io, &read_buf);
            var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor = std.compress.flate.Decompress.init(&tar_reader.interface, .gzip, &window_buffer);

            try std.tar.extract(io, dest_dir, &decompressor.reader, .{});
        } else {
            std.log.err("unsupported archive format for '{s}'", .{dep.url});
            return error.UnsupportedArchiveFormat;
        }

        var walker = try dest_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (std.mem.eql(u8, entry.basename, "build.zig.zon")) {
                const found_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, entry.path });
                std.log.info("discovered transitive ZON manifest at '{s}'", .{found_path});
                return found_path;
            }
        }
    }

    return null;
}

/// Serializes all evaluated dependency entries into a formatted Nix `linkFarm` derivation written to `stdout`.
fn writeNixExpression(io: std.Io, entries: []const NixEntry) !void {
    const stdout_file = std.Io.File.stdout();
    var bw = stdout_file.writer(io, &.{});

    try bw.interface.writeAll("# generated by custom zig dependency processor\n\n{\n  linkFarm,\n  fetchzip,\n  fetchgit,\n}:\n\nlinkFarm \"zig-packages\" [\n");

    for (entries) |entry| {
        try bw.interface.print("  {{\n", .{});
        try bw.interface.print("    name = \"{s}\";\n", .{entry.zon_hash});
        if (entry.is_git) {
            try bw.interface.print("    path = fetchgit {{\n", .{});
            try bw.interface.print("      url = \"{s}\";\n", .{entry.repo_url});
            try bw.interface.print("      rev = \"{s}\";\n", .{entry.rev});
            try bw.interface.print("      hash = \"{s}\";\n", .{entry.sri_hash});
            try bw.interface.print("    }};\n", .{});
        } else {
            try bw.interface.print("    path = fetchzip {{\n", .{});
            try bw.interface.print("      url = \"{s}\";\n", .{entry.url});
            try bw.interface.print("      hash = \"{s}\";\n", .{entry.sri_hash});
            try bw.interface.print("    }};\n", .{});
        }
        try bw.interface.writeAll("  }\n");
    }

    try bw.interface.writeAll("]\n");
    try bw.flush();
}

/// Main entry point for the ZON to Nix dependency processing tool.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    const root_zon_path = "build.zig.zon";
    const nix_deps_path = "nix/deps.nix";

    std.log.info("starting dependency resolution from root '{s}'", .{root_zon_path});

    var visited_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited_hashes.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited_hashes.deinit();
    }

    var entries = std.ArrayList(NixEntry).empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.zon_hash);
            allocator.free(e.url);
            allocator.free(e.sri_hash);
            allocator.free(e.repo_url);
            allocator.free(e.rev);
        }
        entries.deinit(allocator);
    }

    var queue = std.ArrayList([]const u8).empty;
    defer {
        for (queue.items) |q| allocator.free(q);
        queue.deinit(allocator);
    }

    try queue.append(allocator, try allocator.dupe(u8, root_zon_path));

    var tmp_count: usize = 0;

    while (queue.items.len > 0) {
        const curr_zon = queue.swapRemove(0);
        defer allocator.free(curr_zon);

        std.log.info("parsing ZON manifest '{s}'...", .{curr_zon});

        var deps = try parseZonDependencies(allocator, io, curr_zon);
        defer {
            for (deps.items) |d| {
                allocator.free(d.key);
                allocator.free(d.url);
                allocator.free(d.hash);
            }
            deps.deinit(allocator);
        }

        for (deps.items) |dep| {
            if (visited_hashes.contains(dep.hash)) {
                std.log.info("skipping already visited package '{s}' ({s})", .{ dep.key, dep.hash });
                continue;
            }
            try visited_hashes.put(try allocator.dupe(u8, dep.hash), {});

            std.log.info("processing dependency '{s}' (url: {s})", .{ dep.key, dep.url });

            const git_info = try parseGitUrl(allocator, dep.url);
            defer {
                allocator.free(git_info.repo_url);
                allocator.free(git_info.rev);
            }

            var sri_hash: ?[]const u8 = if (git_info.is_git)
                prefetchGitHash(allocator, io, git_info.repo_url, git_info.rev) catch null
            else
                prefetchUrlHash(allocator, io, dep.url) catch null;

            var used_lookup = false;
            if (sri_hash == null) {
                sri_hash = try lookupExistingHash(allocator, io, nix_deps_path, dep.hash);
                used_lookup = true;
            }

            if (sri_hash == null) {
                std.log.err("unable to determine SRI hash for dependency '{s}' ({s})", .{ dep.key, dep.url });
                return error.MissingSriHash;
            }

            const final_sri = sri_hash.?;
            if (used_lookup) {
                std.log.info("reused existing SRI hash '{s}' for '{s}' from '{s}'", .{ final_sri, dep.key, nix_deps_path });
            } else {
                std.log.info("prefetched SRI hash '{s}' for '{s}'", .{ final_sri, dep.key });
            }

            try entries.append(allocator, .{
                .zon_hash = try allocator.dupe(u8, dep.hash),
                .url = try allocator.dupe(u8, dep.url),
                .sri_hash = final_sri,
                .is_git = git_info.is_git,
                .repo_url = try allocator.dupe(u8, git_info.repo_url),
                .rev = try allocator.dupe(u8, git_info.rev),
            });

            switch (try checkCachedPackage(allocator, io, environ_map, dep.hash)) {
                .zon_found => |cached_zon| {
                    defer allocator.free(cached_zon);
                    std.log.info("reusing cached ZON for '{s}' at '{s}'", .{ dep.key, cached_zon });
                    try queue.append(allocator, try allocator.dupe(u8, cached_zon));
                    continue;
                },
                .package_cached_no_zon => |cached_dir| {
                    defer allocator.free(cached_dir);
                    std.log.info("reusing cached package for '{s}' at '{s}' (no ZON manifest)", .{ dep.key, cached_dir });
                    continue;
                },
                .not_cached => {},
            }

            tmp_count += 1;
            if (try fetchAndExtractZon(allocator, io, dep, git_info, tmp_count)) |transitive_zon| {
                try queue.append(allocator, transitive_zon);
            }
        }
    }

    std.log.info("completed dependency graph resolution (total packages: {})", .{entries.items.len});

    try writeNixExpression(io, entries.items);
}
