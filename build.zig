const std = @import("std");

/// Configures the build pipeline, targets, dependencies, shader compilation, and test runner for Peng.
pub fn build(b: *std.Build) void {
    const hot_reload = b.option(
        bool,
        "hot_reload",
        "Build the application viewer as a dynamic lib to allow for automatic hot-reload of code",
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
    // Transitively retrieve the clay dependency from zclay's sub-builder
    const clay_dep = zclay_dep.builder.dependency("clay", .{});

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

    // Create the standalone SDL boundary module
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
            sdl_module.addIncludePath(dep.path("include"));
            sdl_module.addLibraryPath(dep.path("lib/x64"));
        }
        const sys_libs = [_][]const u8{ "SDL3", "SDL3_ttf", "SDL3_image" };
        inline for (sys_libs) |lib| {
            sdl_module.linkSystemLibrary(lib, .{});
        }

        const install_bin = struct {
            fn run(builder: *std.Build, lazy_path: std.Build.LazyPath, filename: []const u8) void {
                const install_step = builder.addInstallBinFile(lazy_path, filename);
                builder.getInstallStep().dependOn(&install_step.step);
            }
        }.run;

        install_bin(b, sdl3_dep.path("lib/x64/SDL3.dll"), "SDL3.dll");
        install_bin(b, ttf_dep.path("lib/x64/SDL3_ttf.dll"), "SDL3_ttf.dll");
        install_bin(b, img_dep.path("lib/x64/SDL3_image.dll"), "SDL3_image.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libavif-16.dll"), "libavif-16.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libpng16-16.dll"), "libpng16-16.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libtiff-6.dll"), "libtiff-6.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebp-7.dll"), "libwebp-7.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebpdemux-2.dll"), "libwebpdemux-2.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebpmux-3.dll"), "libwebpmux-3.dll");
    } else {
        const sys_libs = [_][]const u8{ "sdl3", "sdl3-ttf", "sdl3-image" };
        inline for (sys_libs) |lib| {
            sdl_module.linkSystemLibrary(lib, .{});
        }
    }

    const intents_module = b.createModule(.{
        .root_source_file = b.path("src/intents/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const state_module = b.createModule(.{
        .root_source_file = b.path("src/state/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_module.addImport("intents", intents_module);
    state_module.addImport("sdl", sdl_module);
    state_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    state_module.addImport("zclay", zclay_dep.module("zclay"));

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
    ipc_module.addImport("sdl", sdl_module);
    ipc_module.addImport("intents", intents_module);

    app_module.addImport("sdl", sdl_module);
    app_module.addImport("zclay", zclay_dep.module("zclay"));
    app_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    app_module.addImport("intents", intents_module);
    app_module.addImport("state", state_module);
    app_module.addImport("input", input_module);
    app_module.addImport("ipc", ipc_module);

    ui_module.addImport("sdl", sdl_module);
    ui_module.addImport("zclay", zclay_dep.module("zclay"));
    ui_module.addImport("intents", intents_module);
    ui_module.addImport("state", state_module);
    ui_module.addImport("ipc", ipc_module);

    config_module.addImport("intents", intents_module);

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
    viewer_lib.root_module.addImport("sdl", sdl_module);
    viewer_lib.root_module.addImport("zclay", zclay_dep.module("zclay"));
    viewer_lib.root_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    viewer_lib.root_module.addImport("app", app_module);
    viewer_lib.root_module.addImport("ui", ui_module);
    viewer_lib.root_module.addImport("state", state_module);
    viewer_lib.root_module.addImport("config", config_module);
    viewer_lib.root_module.addImport("intents", intents_module);
    viewer_lib.root_module.addImport("input", input_module);
    viewer_lib.root_module.addImport("ipc", ipc_module);
    viewer_lib.root_module.addIncludePath(clay_dep.path(""));
    viewer_lib.root_module.addIncludePath(clay_dep.path("renderers/SDL3"));

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

    // Import the sdl module into executable module
    exe.root_module.addImport("sdl", sdl_module);

    // Import the zclay Zig module into our executable module
    exe.root_module.addImport("zclay", zclay_dep.module("zclay"));

    // Import internal modules into executable module
    exe.root_module.addImport("app", app_module);
    exe.root_module.addImport("ui", ui_module);
    exe.root_module.addImport("state", state_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("ipc", ipc_module);
    exe.root_module.addImport("input", input_module);
    exe.root_module.addImport("intents", intents_module);

    // Include Clay and its SDL3 renderer via root_module
    exe.root_module.addIncludePath(clay_dep.path(""));
    exe.root_module.addIncludePath(clay_dep.path("renderers/SDL3"));

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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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
    b.installArtifact(test_runner_exe);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());

    const run_integration_tests = b.addRunArtifact(test_runner_exe);
    run_integration_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_integration_tests.addArgs(args);
    }

    const sdl_tests = b.addTest(.{
        .root_module = sdl_module,
    });
    const run_sdl_tests = b.addRunArtifact(sdl_tests);
    run_sdl_tests.step.dependOn(b.getInstallStep());

    const intents_tests = b.addTest(.{
        .root_module = intents_module,
    });
    const run_intents_tests = b.addRunArtifact(intents_tests);
    run_intents_tests.step.dependOn(b.getInstallStep());

    const config_tests = b.addTest(.{
        .root_module = config_module,
    });
    const run_config_tests = b.addRunArtifact(config_tests);
    run_config_tests.step.dependOn(b.getInstallStep());

    if (target.result.os.tag == .windows) {
        run_exe_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_sdl_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_intents_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_config_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_integration_tests.addPathDir(b.getInstallPath(.bin, ""));
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_sdl_tests.step);
    test_step.dependOn(&run_intents_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}

/// Configures GLSL to SPIR-V and SPIR-V to MSL compilation for all shader stages in src/ui/shaders.
/// Uses content-addressed caching with declared inputs and outputs so unmodified shaders are not recompiled.
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
        const src_rel = b.fmt("src/ui/shaders/{s}", .{def.src_name});
        const spv_rel = b.fmt("src/ui/shaders/{s}.spv", .{def.out_name});
        const msl_rel = b.fmt("src/ui/shaders/{s}.msl", .{def.out_name});

        const spv_cmd = b.addSystemCommand(&.{
            "glslangValidator",
            "-V",
            "-Os",
            "-S",
            def.stage,
        });
        spv_cmd.addFileArg(b.path(src_rel));
        spv_cmd.addArg("-o");
        const spv_out = spv_cmd.addOutputFileArg(b.fmt("{s}.spv", .{def.out_name}));

        const msl_cmd = b.addSystemCommand(&.{
            "spirv-cross",
        });
        msl_cmd.addFileArg(spv_out);
        msl_cmd.addArgs(&.{ "--msl", "--output" });
        const msl_out = msl_cmd.addOutputFileArg(b.fmt("{s}.msl", .{def.out_name}));

        update_shaders.addCopyFileToSource(spv_out, spv_rel);
        update_shaders.addCopyFileToSource(msl_out, msl_rel);
    }

    compile_shaders.dependOn(&update_shaders.step);
    return compile_shaders;
}
