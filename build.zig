const std = @import("std");

/// Configures the build pipeline, targets, dependencies, shader compilation,
/// and test runner for Peng.
pub fn build(b: *std.Build) void {
    const hot_reload = b.option(
        bool,
        "hot_reload",
        "Build viewer as dynamic lib for automatic hot-reload of code",
    ) orelse false;

    var options = b.addOptions();
    options.addOption(bool, "hot_reload", hot_reload);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zclay (clay-zig-bindings) dependency
    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });

    if (hot_reload) {
        for (zclay_dep.module("zclay").link_objects.items) |link_obj| {
            switch (link_obj) {
                .other_step => |compile_step| {
                    if (std.mem.eql(u8, compile_step.name, "clay")) {
                        compile_step.root_module.pic = true;
                    }
                },
                else => {},
            }
        }
    }

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
    const wf = b.addWriteFiles();
    const sdl_c_h = wf.add("sdl_c.h",
        \\#include <SDL3/SDL.h>
        \\#include <SDL3/SDL_gpu.h>
        \\#include <SDL3_ttf/SDL_ttf.h>
        \\#include <SDL3_image/SDL_image.h>
        \\
    );
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = sdl_c_h,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sdl_module = b.createModule(.{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        const sdl3_dep = b.dependency("sdl3_devel", .{});
        const ttf_dep = b.dependency("sdl3_ttf_devel", .{});
        const img_dep = b.dependency("sdl3_image_devel", .{});

        const deps = [_]*std.Build.Dependency{ sdl3_dep, ttf_dep, img_dep };
        inline for (deps) |dep| {
            translate_sdl.addIncludePath(dep.path("include"));
            sdl_module.addIncludePath(dep.path("include"));
            sdl_module.addLibraryPath(dep.path("lib/x64"));
        }
        const sys_libs = [_][]const u8{ "SDL3", "SDL3_ttf", "SDL3_image" };
        inline for (sys_libs) |lib| {
            sdl_module.linkSystemLibrary(lib, .{});
        }

        const install_bin = struct {
            fn run(
                builder: *std.Build,
                lazy_path: std.Build.LazyPath,
                filename: []const u8,
            ) void {
                const install_step = builder.addInstallBinFile(
                    lazy_path,
                    filename,
                );
                builder.getInstallStep().dependOn(&install_step.step);
            }
        }.run;

        install_bin(b, sdl3_dep.path("lib/x64/SDL3.dll"), "SDL3.dll");
        install_bin(b, ttf_dep.path("lib/x64/SDL3_ttf.dll"), "SDL3_ttf.dll");
        install_bin(
            b,
            img_dep.path("lib/x64/SDL3_image.dll"),
            "SDL3_image.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libavif-16.dll"),
            "libavif-16.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libpng16-16.dll"),
            "libpng16-16.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libtiff-6.dll"),
            "libtiff-6.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libwebp-7.dll"),
            "libwebp-7.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libwebpdemux-2.dll"),
            "libwebpdemux-2.dll",
        );
        install_bin(
            b,
            img_dep.path("lib/x64/optional/libwebpmux-3.dll"),
            "libwebpmux-3.dll",
        );
    } else {
        const sys_libs = [_][]const u8{ "sdl3", "sdl3-ttf", "sdl3-image" };
        inline for (sys_libs) |lib| {
            translate_sdl.linkSystemLibrary(lib, .{});
            sdl_module.linkSystemLibrary(lib, .{});
        }
    }
    sdl_module.addImport("sdl_c", translate_sdl.createModule());

    const probe_module = b.createModule(.{
        .root_source_file = b.path("src/probe/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vfs_module = b.createModule(.{
        .root_source_file = b.path("src/vfs/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const triage_module = b.createModule(.{
        .root_source_file = b.path("src/triage/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    triage_module.addImport("vfs", vfs_module);

    const intents_module = b.createModule(.{
        .root_source_file = b.path("src/intents/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    intents_module.addImport("triage", triage_module);

    const thumbcache_module = b.createModule(.{
        .root_source_file = b.path("src/thumbcache/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumbcache_module.addImport("probe", probe_module);
    thumbcache_module.addImport("vfs", vfs_module);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/app/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const palette_module = b.createModule(.{
        .root_source_file = b.path("src/palette/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    palette_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    palette_module.addImport("intents", intents_module);
    palette_module.addImport("vfs", vfs_module);

    const state_module = b.createModule(.{
        .root_source_file = b.path("src/state/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_module.addImport("intents", intents_module);
    state_module.addImport("palette", palette_module);
    state_module.addImport("triage", triage_module);
    state_module.addImport("vfs", vfs_module);

    const input_module = b.createModule(.{
        .root_source_file = b.path("src/input/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_module.addImport("sdl", sdl_module);
    input_module.addImport("state", state_module);
    input_module.addImport("intents", intents_module);

    const ipc_module = b.createModule(.{
        .root_source_file = b.path("src/ipc/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_module.addImport("intents", intents_module);
    ipc_module.addImport("triage", triage_module);

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_module.addImport("ipc", ipc_module);
    core_module.addImport("probe", probe_module);
    core_module.addImport("sdl", sdl_module);
    core_module.addImport("state", state_module);
    core_module.addImport("thumbcache", thumbcache_module);
    core_module.addImport("triage", triage_module);
    core_module.addImport("vfs", vfs_module);

    const gpu_module = b.createModule(.{
        .root_source_file = b.path("src/gpu/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_module.addImport("sdl", sdl_module);
    gpu_module.addImport("state", state_module);

    app_module.addImport("core", core_module);
    app_module.addImport("gpu", gpu_module);
    app_module.addImport("input", input_module);
    app_module.addImport("intents", intents_module);
    app_module.addImport("ipc", ipc_module);
    app_module.addImport("palette", palette_module);
    app_module.addImport("probe", probe_module);
    app_module.addImport("sdl", sdl_module);
    app_module.addImport("state", state_module);
    app_module.addImport("thumbcache", thumbcache_module);
    app_module.addImport("triage", triage_module);
    app_module.addImport("ui", ui_module);
    app_module.addImport("vfs", vfs_module);

    ui_module.addImport("core", core_module);
    ui_module.addImport("gpu", gpu_module);
    ui_module.addImport("intents", intents_module);
    ui_module.addImport("palette", palette_module);
    ui_module.addImport("state", state_module);
    ui_module.addImport("triage", triage_module);
    ui_module.addImport("vfs", vfs_module);
    ui_module.addImport("zclay", zclay_dep.module("zclay"));

    config_module.addImport("intents", intents_module);
    config_module.addImport("thumbcache", thumbcache_module);

    const viewer_lib = b.addLibrary(.{
        .name = "viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = if (hot_reload) .dynamic else .static,
    });
    viewer_lib.root_module.addImport("app", app_module);
    viewer_lib.root_module.addImport("gpu", gpu_module);
    viewer_lib.root_module.addImport("input", input_module);
    viewer_lib.root_module.addImport("sdl", sdl_module);
    viewer_lib.root_module.addImport("ui", ui_module);

    if (hot_reload) {
        b.installArtifact(viewer_lib);
    }

    const exe = b.addExecutable(.{
        .name = "peng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    // Import internal and external modules into executable module
    exe.root_module.addImport("app", app_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("core", core_module);
    exe.root_module.addImport("gpu", gpu_module);
    exe.root_module.addImport("ipc", ipc_module);
    exe.root_module.addImport("sdl", sdl_module);
    exe.root_module.addImport("state", state_module);
    exe.root_module.addImport("thumbcache", thumbcache_module);
    exe.root_module.addImport("ui", ui_module);

    if (hot_reload) {
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
        }),
    });
    msg_exe.root_module.addImport("config", config_module);
    msg_exe.root_module.addImport("ipc", ipc_module);
    b.installArtifact(msg_exe);

    const test_runner_exe = b.addExecutable(.{
        .name = "peng-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_runner_exe.root_module.addImport("sdl", sdl_module);
    test_runner_exe.root_module.addImport("ipc", ipc_module);
    b.installArtifact(test_runner_exe);

    const run_integration_tests = b.addRunArtifact(test_runner_exe);
    run_integration_tests.setCwd(b.path("."));
    run_integration_tests.step.dependOn(b.getInstallStep());
    run_integration_tests.addPassthruArgs();

    const sdl_tests = b.addTest(.{
        .root_module = sdl_module,
    });
    const run_sdl_tests = b.addRunArtifact(sdl_tests);

    const intents_tests = b.addTest(.{
        .root_module = intents_module,
    });
    const run_intents_tests = b.addRunArtifact(intents_tests);

    const config_tests = b.addTest(.{
        .root_module = config_module,
    });
    const run_config_tests = b.addRunArtifact(config_tests);

    const state_tests = b.addTest(.{
        .root_module = state_module,
    });
    const run_state_tests = b.addRunArtifact(state_tests);

    const input_tests = b.addTest(.{
        .root_module = input_module,
    });
    const run_input_tests = b.addRunArtifact(input_tests);

    const ipc_tests = b.addTest(.{
        .root_module = ipc_module,
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    const app_tests = b.addTest(.{
        .root_module = app_module,
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    run_app_tests.setCwd(b.path("."));

    const ui_tests = b.addTest(.{
        .root_module = ui_module,
    });
    ui_tests.step.dependOn(compile_shaders);
    const run_ui_tests = b.addRunArtifact(ui_tests);

    const core_tests = b.addTest(.{
        .root_module = core_module,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    run_core_tests.setCwd(b.path("."));

    const probe_tests = b.addTest(.{
        .root_module = probe_module,
    });
    const run_probe_tests = b.addRunArtifact(probe_tests);
    run_probe_tests.setCwd(b.path("."));

    const vfs_tests = b.addTest(.{
        .root_module = vfs_module,
    });
    const run_vfs_tests = b.addRunArtifact(vfs_tests);
    run_vfs_tests.setCwd(b.path("."));

    const triage_tests = b.addTest(.{
        .root_module = triage_module,
    });
    const run_triage_tests = b.addRunArtifact(triage_tests);
    run_triage_tests.setCwd(b.path("."));

    const palette_tests = b.addTest(.{
        .root_module = palette_module,
    });
    const run_palette_tests = b.addRunArtifact(palette_tests);
    run_palette_tests.setCwd(b.path("."));

    const thumbcache_tests = b.addTest(.{
        .root_module = thumbcache_module,
    });
    const run_thumbcache_tests = b.addRunArtifact(thumbcache_tests);
    run_thumbcache_tests.setCwd(b.path("."));

    const gpu_tests = b.addTest(.{
        .root_module = gpu_module,
    });
    gpu_tests.step.dependOn(compile_shaders);
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    run_gpu_tests.setCwd(b.path("."));

    if (target.result.os.tag == .windows) {
        const win_runs = [_]*std.Build.Step.Run{
            run_sdl_tests,
            run_gpu_tests,
            run_state_tests,
            run_core_tests,
            run_probe_tests,
            run_thumbcache_tests,
            run_triage_tests,
            run_palette_tests,
            run_vfs_tests,
            run_app_tests,
            run_ui_tests,
            run_intents_tests,
            run_config_tests,
            run_input_tests,
            run_ipc_tests,
            run_integration_tests,
        };
        const prev_path = b.graph.environ_map.get("PATH") orelse "";
        const new_path = if (prev_path.len > 0)
            b.fmt("zig-out\\bin;{s}", .{prev_path})
        else
            "zig-out\\bin";
        for (win_runs) |win_run| {
            win_run.step.dependOn(b.getInstallStep());
            win_run.setEnvironmentVariable("PATH", new_path);
        }
    }

    const test_gpu_step = b.step("test-gpu", "Run gpu tests");
    test_gpu_step.dependOn(&run_gpu_tests.step);

    const test_probe_step = b.step("test-probe", "Run probe tests");
    test_probe_step.dependOn(&run_probe_tests.step);

    const test_state_step = b.step(
        "test-state",
        "Run state module unit tests",
    );
    test_state_step.dependOn(&run_state_tests.step);

    const test_core_step = b.step("test-core", "Run core tests");
    test_core_step.dependOn(&run_core_tests.step);

    const test_palette_step = b.step("test-palette", "Run palette tests");
    test_palette_step.dependOn(&run_palette_tests.step);

    const test_triage_step = b.step("test-triage", "Run triage tests");
    test_triage_step.dependOn(&run_triage_tests.step);

    const test_vfs_step = b.step("test-vfs", "Run vfs tests");
    test_vfs_step.dependOn(&run_vfs_tests.step);

    const test_thumbcache_step = b.step(
        "test-thumbcache",
        "Run thumbcache tests",
    );
    test_thumbcache_step.dependOn(&run_thumbcache_tests.step);

    const test_ui_step = b.step("test-ui", "Run ui tests");
    test_ui_step.dependOn(&run_ui_tests.step);

    const test_unit_step = b.step("test-unit", "Run all unit tests");
    test_unit_step.dependOn(&run_sdl_tests.step);
    test_unit_step.dependOn(&run_gpu_tests.step);
    test_unit_step.dependOn(&run_state_tests.step);
    test_unit_step.dependOn(&run_core_tests.step);
    test_unit_step.dependOn(&run_probe_tests.step);
    test_unit_step.dependOn(&run_thumbcache_tests.step);
    test_unit_step.dependOn(&run_palette_tests.step);
    test_unit_step.dependOn(&run_triage_tests.step);
    test_unit_step.dependOn(&run_vfs_tests.step);
    test_unit_step.dependOn(&run_app_tests.step);
    test_unit_step.dependOn(&run_ui_tests.step);
    test_unit_step.dependOn(&run_intents_tests.step);
    test_unit_step.dependOn(&run_config_tests.step);
    test_unit_step.dependOn(&run_input_tests.step);
    test_unit_step.dependOn(&run_ipc_tests.step);

    const test_integration_step = b.step(
        "test-integration",
        "Run integration tests",
    );
    test_integration_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_sdl_tests.step);
    test_step.dependOn(&run_gpu_tests.step);
    test_step.dependOn(&run_state_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_probe_tests.step);
    test_step.dependOn(&run_thumbcache_tests.step);
    test_step.dependOn(&run_palette_tests.step);
    test_step.dependOn(&run_triage_tests.step);
    test_step.dependOn(&run_vfs_tests.step);
    test_step.dependOn(&run_app_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_intents_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_input_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
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
            .src_name = "ui.frag.glsl",
            .out_name = "ui.frag",
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

        const msl_cmd = b.addSystemCommand(&.{
            "spirv-cross",
        });
        msl_cmd.addFileArg2(spv_out, .{});
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
