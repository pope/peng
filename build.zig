const std = @import("std");

/// Configures the build pipeline, targets, dependencies, shader compilation,
/// and test runner for Peng.
pub fn build(b: *std.Build) void {
    const hot_reload = b.option(
        bool,
        "hot_reload",
        "Build viewer as dynamic lib for automatic hot-reload of code",
    ) orelse false;

    const static_sdl = b.option(
        bool,
        "static_sdl",
        "Statically link SDL3, SDL3_ttf, and SDL3_image",
    ) orelse false;

    if (hot_reload and static_sdl) {
        @panic("-Dhot_reload=true cannot be combined with -Dstatic_sdl=true");
    }

    var options = b.addOptions();
    options.addOption(bool, "hot_reload", hot_reload);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const fuzzig_dep = b.dependency("fuzzig", .{
        .target = target,
        .optimize = optimize,
    });
    // TODO: Remove this WriteFiles workaround once upstream fuzzig removes
    // Zig 0.16 `**` array repetition syntax from its test blocks in root.zig.
    const fuzzig_mod = fuzzig_dep.module("fuzzig");
    {
        const fuzzig_dir = fuzzig_dep.builder.root.root_dir.handle;
        const fuzzig_src = fuzzig_dir.readFileAlloc(
            b.graph.io,
            "src/root.zig",
            b.allocator,
            .unlimited,
        ) catch @panic("OOM");
        const cutoff = std.mem.find(u8, fuzzig_src, "\nfn doTestScore(") orelse
            fuzzig_src.len;
        const fuzzig_wf = b.addWriteFiles();
        _ = fuzzig_wf.addCopyFile(
            fuzzig_dep.path("src/utils.zig"),
            "utils.zig",
        );
        _ = fuzzig_wf.addCopyFile(
            fuzzig_dep.path("src/structures.zig"),
            "structures.zig",
        );
        _ = fuzzig_wf.addCopyFile(
            fuzzig_dep.path("src/unicode.zig"),
            "unicode.zig",
        );
        fuzzig_mod.root_source_file = fuzzig_wf.add(
            "root.zig",
            fuzzig_src[0..cutoff],
        );
    }

    // Create the standalone SDL boundary module
    const is_darwin = target.result.os.tag.isDarwin();
    const is_windows = target.result.os.tag == .windows;
    const has_turbojpeg = !is_windows;

    const wf = b.addWriteFiles();
    const sdl_c_header = if (has_turbojpeg)
        \\#include <SDL3/SDL.h>
        \\#include <SDL3/SDL_gpu.h>
        \\#include <SDL3_ttf/SDL_ttf.h>
        \\#include <SDL3_image/SDL_image.h>
        \\#include <turbojpeg.h>
        \\
    else
        \\#include <SDL3/SDL.h>
        \\#include <SDL3/SDL_gpu.h>
        \\#include <SDL3_ttf/SDL_ttf.h>
        \\#include <SDL3_image/SDL_image.h>
        \\
    ;
    const sdl_c_h = wf.add("sdl_c.h", sdl_c_header);
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = sdl_c_h,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sdl_options = b.addOptions();
    sdl_options.addOption(bool, "has_turbojpeg", has_turbojpeg);

    const sdl_module = b.createModule(.{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sdl_module.addOptions("sdl_options", sdl_options);

    if (is_windows) {
        linkWindowsSdl(b, translate_sdl, sdl_module);
    } else {
        const link_mode: std.builtin.LinkMode = if (static_sdl)
            .static
        else
            .dynamic;
        // translate_sdl.createModule() forwards system_libs into sdl_c; static
        // codecs (libjxl, harfbuzz, libyuv) also need C++ runtime linkage.
        const sys_libs = [_][]const u8{
            "sdl3",
            "sdl3-ttf",
            "sdl3-image",
            "libturbojpeg",
        };
        inline for (sys_libs) |lib| {
            translate_sdl.linkSystemLibrary(lib, .{
                .preferred_link_mode = link_mode,
            });
        }
        if (static_sdl) {
            sdl_module.link_libcpp = true;
            if (is_darwin) {
                linkDarwinStaticSdl(
                    b,
                    target.result,
                    translate_sdl,
                    sdl_module,
                );
            }
        }
    }
    sdl_module.addImport("sdl_c", translate_sdl.createModule());

    const geom_module = createInternalModule(
        b,
        target,
        optimize,
        "src/geom/root.zig",
        &.{},
    );
    const probe_module = createInternalModule(
        b,
        target,
        optimize,
        "src/probe/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
        },
    );
    const vfs_module = createInternalModule(
        b,
        target,
        optimize,
        "src/vfs/root.zig",
        &.{},
    );
    const triage_module = createInternalModule(
        b,
        target,
        optimize,
        "src/triage/root.zig",
        &.{
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const intents_module = createInternalModule(
        b,
        target,
        optimize,
        "src/intents/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "triage", .module = triage_module },
        },
    );
    const thumbcache_module = createInternalModule(
        b,
        target,
        optimize,
        "src/thumbcache/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "probe", .module = probe_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const termgfx_module = createInternalModule(
        b,
        target,
        optimize,
        "src/termgfx/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
        },
    );
    const config_module = createInternalModule(
        b,
        target,
        optimize,
        "src/config/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "termgfx", .module = termgfx_module },
            .{ .name = "thumbcache", .module = thumbcache_module },
        },
    );
    const palette_module = createInternalModule(
        b,
        target,
        optimize,
        "src/palette/root.zig",
        &.{
            .{ .name = "fuzzig", .module = fuzzig_mod },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const state_module = createInternalModule(
        b,
        target,
        optimize,
        "src/state/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "palette", .module = palette_module },
            .{ .name = "triage", .module = triage_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const input_module = createInternalModule(
        b,
        target,
        optimize,
        "src/input/root.zig",
        &.{
            .{ .name = "intents", .module = intents_module },
            .{ .name = "sdl", .module = sdl_module },
            .{ .name = "state", .module = state_module },
        },
    );
    const ipc_module = createInternalModule(
        b,
        target,
        optimize,
        "src/ipc/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "triage", .module = triage_module },
        },
    );
    const cache_module = createInternalModule(
        b,
        target,
        optimize,
        "src/cache/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "probe", .module = probe_module },
            .{ .name = "sdl", .module = sdl_module },
            .{ .name = "state", .module = state_module },
            .{ .name = "triage", .module = triage_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const core_module = createInternalModule(
        b,
        target,
        optimize,
        "src/core/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "probe", .module = probe_module },
            .{ .name = "sdl", .module = sdl_module },
            .{ .name = "thumbcache", .module = thumbcache_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const gpu_module = createInternalModule(
        b,
        target,
        optimize,
        "src/gpu/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "sdl", .module = sdl_module },
            .{ .name = "state", .module = state_module },
        },
    );
    const ui_module = createInternalModule(
        b,
        target,
        optimize,
        "src/ui/root.zig",
        &.{
            .{ .name = "cache", .module = cache_module },
            .{ .name = "geom", .module = geom_module },
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "palette", .module = palette_module },
            .{ .name = "state", .module = state_module },
            .{ .name = "triage", .module = triage_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const tui_module = createInternalModule(
        b,
        target,
        optimize,
        "src/tui/root.zig",
        &.{
            .{ .name = "geom", .module = geom_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "palette", .module = palette_module },
            .{ .name = "state", .module = state_module },
            .{ .name = "termgfx", .module = termgfx_module },
            .{ .name = "thumbcache", .module = thumbcache_module },
            .{ .name = "triage", .module = triage_module },
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "vfs", .module = vfs_module },
        },
    );
    const app_module = createInternalModule(
        b,
        target,
        optimize,
        "src/app/root.zig",
        &.{
            .{ .name = "cache", .module = cache_module },
            .{ .name = "core", .module = core_module },
            .{ .name = "geom", .module = geom_module },
            .{ .name = "gpu", .module = gpu_module },
            .{ .name = "input", .module = input_module },
            .{ .name = "intents", .module = intents_module },
            .{ .name = "ipc", .module = ipc_module },
            .{ .name = "probe", .module = probe_module },
            .{ .name = "sdl", .module = sdl_module },
            .{ .name = "state", .module = state_module },
            .{ .name = "thumbcache", .module = thumbcache_module },
            .{ .name = "triage", .module = triage_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    );

    const viewer_lib = b.addLibrary(.{
        .name = "viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = app_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "input", .module = input_module },
                .{ .name = "sdl", .module = sdl_module },
                .{ .name = "state", .module = state_module },
                .{ .name = "ui", .module = ui_module },
            },
        }),
        .linkage = if (hot_reload) .dynamic else .static,
    });

    if (hot_reload) {
        viewer_lib.dead_strip_dylibs = is_darwin;
        b.installArtifact(viewer_lib);
    }

    const exe = b.addExecutable(.{
        .name = "peng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = app_module },
                .{ .name = "config", .module = config_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "ipc", .module = ipc_module },
                .{ .name = "sdl", .module = sdl_module },
                .{ .name = "state", .module = state_module },
                .{ .name = "thumbcache", .module = thumbcache_module },
                .{ .name = "ui", .module = ui_module },
            },
        }),
    });
    // Prune duplicate -lSDL3 LC_LOAD_DYLIBs from transitive pkg-config files;
    // -ObjC keeps Cocoa/Metal categories in libSDL3.a from being dead-stripped.
    exe.dead_strip_dylibs = is_darwin;
    exe.force_load_objc = is_darwin and static_sdl;
    exe.root_module.addOptions("build_options", options);

    if (hot_reload) {
        // Export host symbols so dlopen'd libviewer resolves shared globals.
        exe.rdynamic = true;
    } else {
        exe.root_module.addImport("viewer", viewer_lib.root_module);
    }

    b.installArtifact(exe);

    // Shader compilation
    const compile_shaders = setupShaderCompilation(b);
    exe.step.dependOn(compile_shaders);
    viewer_lib.step.dependOn(compile_shaders);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const msg_exe = b.addExecutable(.{
        .name = "peng-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/msg_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "config", .module = config_module },
                .{ .name = "geom", .module = geom_module },
                .{ .name = "ipc", .module = ipc_module },
                .{ .name = "termgfx", .module = termgfx_module },
            },
        }),
    });
    msg_exe.dead_strip_dylibs = is_darwin;
    b.installArtifact(msg_exe);

    const preview_exe = b.addExecutable(.{
        .name = "peng-preview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preview_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "config", .module = config_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "termgfx", .module = termgfx_module },
                .{ .name = "thumbcache", .module = thumbcache_module },
            },
        }),
    });
    preview_exe.dead_strip_dylibs = is_darwin;
    preview_exe.force_load_objc = is_darwin and static_sdl;
    b.installArtifact(preview_exe);

    const tui_exe = b.addExecutable(.{
        .name = "peng-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = app_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "geom", .module = geom_module },
                .{ .name = "gpu", .module = gpu_module },
                .{ .name = "sdl", .module = sdl_module },
                .{ .name = "state", .module = state_module },
                .{ .name = "termgfx", .module = termgfx_module },
                .{ .name = "tui", .module = tui_module },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    tui_exe.dead_strip_dylibs = is_darwin;
    tui_exe.force_load_objc = is_darwin and static_sdl;
    tui_exe.step.dependOn(compile_shaders);
    b.installArtifact(tui_exe);

    const precache_exe = b.addExecutable(.{
        .name = "peng-precache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/precache_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "config", .module = config_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "sdl", .module = sdl_module },
                .{ .name = "thumbcache", .module = thumbcache_module },
            },
        }),
    });
    precache_exe.dead_strip_dylibs = is_darwin;
    precache_exe.force_load_objc = is_darwin and static_sdl;
    b.installArtifact(precache_exe);

    const test_runner_exe = b.addExecutable(.{
        .name = "peng-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ipc", .module = ipc_module },
                .{ .name = "sdl", .module = sdl_module },
            },
        }),
    });
    test_runner_exe.dead_strip_dylibs = is_darwin;
    test_runner_exe.force_load_objc = is_darwin and static_sdl;
    b.installArtifact(test_runner_exe);

    const run_integration_tests = b.addRunArtifact(test_runner_exe);
    run_integration_tests.setCwd(b.path("."));
    run_integration_tests.step.dependOn(b.getInstallStep());
    run_integration_tests.addPassthruArgs();

    // Windows PE lacks rpath, and addRunArtifact executes directly out of
    // .zig-cache/o/<hash>/; prepend zig-out\bin so tests find installed DLLs.
    const win_test_path: ?[]const u8 = if (is_windows) blk: {
        const prev_path = b.graph.environ_map.get("PATH") orelse "";
        break :blk if (prev_path.len > 0)
            b.fmt("zig-out\\bin;{s}", .{prev_path})
        else
            "zig-out\\bin";
    } else null;

    if (win_test_path) |new_path| {
        run_integration_tests.setEnvironmentVariable("PATH", new_path);
    }

    const UnitTestSpec = struct {
        module: *std.Build.Module,
        step_name: ?[]const u8 = null,
        step_desc: []const u8 = "",
        needs_cwd: bool = false,
        needs_shaders: bool = false,
    };

    const unit_test_specs = [_]UnitTestSpec{
        .{ .module = sdl_module },
        .{
            .module = gpu_module,
            .step_name = "test-gpu",
            .step_desc = "Run gpu tests",
            .needs_cwd = true,
            .needs_shaders = true,
        },
        .{
            .module = state_module,
            .step_name = "test-state",
            .step_desc = "Run state module unit tests",
        },
        .{
            .module = cache_module,
            .step_name = "test-cache",
            .step_desc = "Run cache tests",
            .needs_cwd = true,
        },
        .{
            .module = core_module,
            .step_name = "test-core",
            .step_desc = "Run core tests",
            .needs_cwd = true,
        },
        .{
            .module = geom_module,
            .step_name = "test-geom",
            .step_desc = "Run geom module unit tests",
            .needs_cwd = true,
        },
        .{
            .module = probe_module,
            .step_name = "test-probe",
            .step_desc = "Run probe tests",
            .needs_cwd = true,
        },
        .{
            .module = thumbcache_module,
            .step_name = "test-thumbcache",
            .step_desc = "Run thumbcache tests",
            .needs_cwd = true,
        },
        .{
            .module = palette_module,
            .step_name = "test-palette",
            .step_desc = "Run palette tests",
            .needs_cwd = true,
        },
        .{
            .module = triage_module,
            .step_name = "test-triage",
            .step_desc = "Run triage tests",
            .needs_cwd = true,
        },
        .{
            .module = vfs_module,
            .step_name = "test-vfs",
            .step_desc = "Run vfs tests",
            .needs_cwd = true,
        },
        .{
            .module = app_module,
            .needs_cwd = true,
            .needs_shaders = true,
        },
        .{
            .module = ui_module,
            .step_name = "test-ui",
            .step_desc = "Run ui tests",
            .needs_shaders = true,
        },
        .{ .module = intents_module },
        .{ .module = config_module },
        .{ .module = input_module },
        .{
            .module = ipc_module,
            .step_name = "test-ipc",
            .step_desc = "Run ipc tests",
        },
        .{
            .module = termgfx_module,
            .step_name = "test-termgfx",
            .step_desc = "Run termgfx tests",
        },
        .{
            .module = tui_module,
            .step_name = "test-tui",
            .step_desc = "Run tui tests",
        },
    };

    const test_unit_step = b.step("test-unit", "Run all unit tests");
    for (unit_test_specs) |spec| {
        const mod_tests = addModuleTest(b, spec.module);
        if (spec.needs_shaders) {
            mod_tests.step.dependOn(compile_shaders);
        }
        const run_mod_tests = b.addRunArtifact(mod_tests);
        if (spec.needs_cwd) {
            run_mod_tests.setCwd(b.path("."));
        }
        if (win_test_path) |new_path| {
            run_mod_tests.step.dependOn(b.getInstallStep());
            run_mod_tests.setEnvironmentVariable("PATH", new_path);
        }
        if (spec.step_name) |step_name| {
            const named_step = b.step(step_name, spec.step_desc);
            named_step.dependOn(&run_mod_tests.step);
        }
        test_unit_step.dependOn(&run_mod_tests.step);
    }

    const test_integration_step = b.step(
        "test-integration",
        "Run integration tests",
    );
    test_integration_step.dependOn(&run_integration_tests.step);

    const test_hot_reload_step = b.step(
        "test-hot-reload",
        "Run hot-reload dynamic library smoke test",
    );
    if (hot_reload) {
        const hot_reload_tests = addModuleTest(b, exe.root_module);
        hot_reload_tests.step.dependOn(compile_shaders);
        hot_reload_tests.rdynamic = true;
        const run_hot_reload_tests = b.addRunArtifact(hot_reload_tests);
        run_hot_reload_tests.step.dependOn(b.getInstallStep());
        run_hot_reload_tests.setCwd(b.path("."));
        test_hot_reload_step.dependOn(&run_hot_reload_tests.step);
    } else {
        const fail_step = b.addFail(
            "test-hot-reload requires -Dhot_reload=true",
        );
        test_hot_reload_step.dependOn(&fail_step.step);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(test_unit_step);
    test_step.dependOn(&run_integration_tests.step);
}

/// Configures GLSL to SPIR-V and SPIR-V to MSL compilation for all shader
/// stages in src/gpu/shaders.
/// Uses content-addressed caching with declared inputs and outputs so
/// unmodified shaders are not recompiled.
fn setupShaderCompilation(b: *std.Build) *std.Build.Step {
    const compile_shaders = b.step("shaders", "Compile shaders");
    const update_shaders = b.addUpdateSourceFiles();

    const ShaderDef = struct {
        stage: []const u8,
        src_name: []const u8,
        out_name: []const u8,
    };

    const shader_defs = [_]ShaderDef{
        .{
            .stage = "vert",
            .src_name = "vert.glsl",
            .out_name = "vert",
        },
        .{
            .stage = "frag",
            .src_name = "image.frag.glsl",
            .out_name = "image.frag",
        },
        .{
            .stage = "frag",
            .src_name = "blit.frag.glsl",
            .out_name = "blit.frag",
        },
        .{
            .stage = "frag",
            .src_name = "glyph.frag.glsl",
            .out_name = "glyph.frag",
        },
        .{
            .stage = "vert",
            .src_name = "sdf.vert.glsl",
            .out_name = "sdf.vert",
        },
        .{
            .stage = "frag",
            .src_name = "sdf.frag.glsl",
            .out_name = "sdf.frag",
        },
        .{
            .stage = "frag",
            .src_name = "blur_down.frag.glsl",
            .out_name = "blur_down",
        },
        .{
            .stage = "frag",
            .src_name = "blur_up.frag.glsl",
            .out_name = "blur_up",
        },
        .{
            .stage = "comp",
            .src_name = "unpack_rgb.comp.glsl",
            .out_name = "unpack_rgb",
        },
    };

    for (shader_defs) |def| {
        const src_rel = b.fmt("src/gpu/shaders/{s}", .{def.src_name});
        const spv_rel = b.fmt("src/gpu/shaders/{s}.spv", .{def.out_name});
        const msl_rel = b.fmt("src/gpu/shaders/{s}.msl", .{def.out_name});

        const spv_cmd = b.addSystemCommand(&.{
            "glslangValidator",
            "--quiet",
            "-V",
            "-Os",
            "-S",
            def.stage,
        });
        spv_cmd.addFileArg2(b.path(src_rel), .{});
        spv_cmd.addArg("-o");
        const spv_out = spv_cmd.addOutputFileArg2(
            b.fmt("{s}.spv", .{def.out_name}),
            .{},
        );

        // SDL3 GPU's Metal compute ABI binds uniforms ([[buffer(0)]]) before
        // storage buffers ([[buffer(1)]]), opposite of SPIR-V's set 0 vs set 2.
        const is_comp = std.mem.eql(u8, def.stage, "comp");
        const msl_spv_in = if (is_comp) blk: {
            const msl_spv_cmd = b.addSystemCommand(&.{
                "glslangValidator",
                "--quiet",
                "-V",
                "-Os",
                "-DTARGET_MSL",
                "-S",
                def.stage,
            });
            msl_spv_cmd.addFileArg2(b.path(src_rel), .{});
            msl_spv_cmd.addArg("-o");
            break :blk msl_spv_cmd.addOutputFileArg2(
                b.fmt("{s}.msl.spv", .{def.out_name}),
                .{},
            );
        } else spv_out;

        const msl_cmd = b.addSystemCommand(&.{
            "spirv-cross",
        });
        msl_cmd.addFileArg2(msl_spv_in, .{});
        if (is_comp) {
            msl_cmd.addArg("--msl-decoration-binding");
        }
        msl_cmd.addArgs(&.{ "--msl", "--output" });
        const msl_out = msl_cmd.addOutputFileArg2(
            b.fmt("{s}.msl", .{def.out_name}),
            .{},
        );

        update_shaders.addCopyFileToSource(spv_out, spv_rel);
        update_shaders.addCopyFileToSource(msl_out, msl_rel);
    }

    compile_shaders.dependOn(&update_shaders.step);
    return compile_shaders;
}

fn createInternalModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_path: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
}

fn linkWindowsSdl(
    b: *std.Build,
    translate_sdl: *std.Build.Step.TranslateC,
    sdl_module: *std.Build.Module,
) void {
    // Query all 3 lazy deps before returning so Zig fetches them in parallel.
    const sdl3_opt = b.lazyDependency("sdl3_devel", .{});
    const ttf_opt = b.lazyDependency("sdl3_ttf_devel", .{});
    const img_opt = b.lazyDependency("sdl3_image_devel", .{});
    const sdl3_dep = sdl3_opt orelse return;
    const ttf_dep = ttf_opt orelse return;
    const img_dep = img_opt orelse return;

    const deps = [_]*std.Build.Dependency{ sdl3_dep, ttf_dep, img_dep };
    for (deps) |dep| {
        translate_sdl.addIncludePath(dep.path("include"));
        sdl_module.addIncludePath(dep.path("include"));
        sdl_module.addLibraryPath(dep.path("lib/x64"));
    }
    const sys_libs = [_][]const u8{ "SDL3", "SDL3_ttf", "SDL3_image" };
    for (sys_libs) |lib| {
        sdl_module.linkSystemLibrary(lib, .{});
    }

    const DllSpec = struct {
        dep: *std.Build.Dependency,
        sub_path: []const u8,
    };
    const dlls = [_]DllSpec{
        .{ .dep = sdl3_dep, .sub_path = "lib/x64/SDL3.dll" },
        .{ .dep = ttf_dep, .sub_path = "lib/x64/SDL3_ttf.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/SDL3_image.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libavif-16.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libpng16-16.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libtiff-6.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libwebp-7.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libwebpdemux-2.dll" },
        .{ .dep = img_dep, .sub_path = "lib/x64/optional/libwebpmux-3.dll" },
    };
    for (dlls) |dll| {
        const install_dll = b.addInstallBinFile(
            dll.dep.path(dll.sub_path),
            std.Io.Dir.path.basename(dll.sub_path),
        );
        b.getInstallStep().dependOn(&install_dll.step);
    }
}

/// Creates a module unit test binary, enabling `-dead_strip_dylibs` on Darwin
/// so Zig's Mach-O linker prunes duplicate or unused `LC_LOAD_DYLIB` entries.
fn addModuleTest(
    b: *std.Build,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const t = b.addTest(.{ .root_module = root_module });
    const is_darwin = t.rootModuleTarget().os.tag.isDarwin();
    t.dead_strip_dylibs = is_darwin;
    t.force_load_objc = is_darwin and t.dependsOnSystemLibrary("objc");
    return t;
}

/// Links Apple system frameworks and Objective-C runtime stubs required when
/// `libSDL3.a` is statically linked on macOS (`PkgConfig` ignores
/// `-Wl,-framework,...` flags in `sdl3.pc`'s `Libs.private`).
fn linkDarwinStaticSdl(
    b: *std.Build,
    target: std.Target,
    translate_sdl: *std.Build.Step.TranslateC,
    sdl_module: *std.Build.Module,
) void {
    // Explicit macOS target versions skip NativePaths.detect; resolve SDK stub
    // search paths from Nix's SDKROOT or Xcode/CLT's xcrun.
    b.graph.poisonCache();
    const sdk_opt: ?[]const u8 = blk: {
        if (b.graph.environ_map.get("SDKROOT")) |s| {
            if (s.len > 0) break :blk s;
        }
        if (b.graph.host.result.os.tag.isDarwin() and
            std.zig.system.darwin.isSdkInstalled(b.allocator, b.graph.io))
        {
            break :blk std.zig.system.darwin.getSdk(
                b.allocator,
                b.graph.io,
                &target,
            );
        }
        break :blk null;
    };
    if (sdk_opt) |sdk| {
        const fw_path = b.graph.cwdRelativePath(
            b.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
        );
        const inc_path = b.graph.cwdRelativePath(
            b.pathJoin(&.{ sdk, "usr/include" }),
        );
        const lib_path = b.graph.cwdRelativePath(
            b.pathJoin(&.{ sdk, "usr/lib" }),
        );
        translate_sdl.addSystemFrameworkPath(fw_path);
        translate_sdl.addSystemIncludePath(inc_path);
        sdl_module.addSystemFrameworkPath(fw_path);
        sdl_module.addLibraryPath(lib_path);
    }

    sdl_module.linkSystemLibrary("objc", .{ .use_pkg_config = .no });

    const frameworks = [_][]const u8{
        "AVFoundation",
        "AudioToolbox",
        "Carbon",
        "Cocoa",
        "CoreAudio",
        "CoreFoundation",
        "CoreGraphics",
        "CoreMedia",
        "CoreServices",
        "CoreVideo",
        "ForceFeedback",
        "Foundation",
        "GameController",
        "IOKit",
        "Metal",
    };
    for (frameworks) |fw| {
        sdl_module.linkFramework(fw, .{});
    }
    // Retained via -needed_framework because SDL3 looks up CAMetalLayer via
    // NSClassFromString(@"CAMetalLayer") without a direct symbol reference.
    sdl_module.linkFramework("QuartzCore", .{ .needed = true });

    const weak_frameworks = [_][]const u8{
        "CoreHaptics",
        "UniformTypeIdentifiers",
    };
    for (weak_frameworks) |fw| {
        sdl_module.linkFramework(fw, .{ .weak = true });
    }
}
